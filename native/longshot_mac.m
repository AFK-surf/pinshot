#import "mac_platform.h"
#import "longshot_algo.h"
#import <ImageIO/ImageIO.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sys/mman.h>

extern void mb_post(const char *channel, const char *json, size_t len, const uint8_t *bytes, size_t blen);
NSWindow *ps_region_frame(NSWindow *w, NSScreen *s, NSRect pixels, int rgb, int dashed);
void ps_region_frame_close(NSWindow *w);

#define TICK_MS 16
#define SETTLE_MS 180

typedef struct {
  uint8_t *base;
  size_t base_len;
  volatile int32_t refs;
} LongCanvas;

static struct {
  int on;
  int x, y;
  int mx, my, mw, mh;
  LongCanvas *canvas;
  LongCore core;
  int paused;
  int frame_color;
  int frame_dashed;
  int told_h, told_lost, told_full, told_paused, told_pics, told_at, told_dir;
  double begun;
  uint64_t taken_seq;
} L;

static __strong NSScreen *screen;
static __strong NSWindow *frameWin;
static __strong NSTimer *timer;
static double now_ms(void) { return ps_now_ms(); }

static LongCanvas *canvas_alloc(int w) {
  LongCanvas *cv = (LongCanvas *)calloc(1, sizeof *cv);
  if (!cv) return NULL;
  cv->base_len = (size_t)LS_MOST_ROWS * 2 * (size_t)w * 4;
  void *p = mmap(NULL, cv->base_len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  if (p == MAP_FAILED) {
    free(cv);
    return NULL;
  }
  cv->base = (uint8_t *)p;
  cv->refs = 1;
  return cv;
}

static void canvas_release(LongCanvas *cv) {
  if (!cv) return;
  if (__sync_sub_and_fetch(&cv->refs, 1) == 0) {
    if (cv->base) munmap(cv->base, cv->base_len);
    free(cv);
  }
}

static int frame_want_color(void) {
  if (L.paused) return 0x9EA4B2;
  if (L.core.full || L.core.lost) return 0xF5A524;
  return 0x2F9BFF;
}

static void frame_sync_color(void) {
  int c = frame_want_color();
  int d = L.paused ? 1 : 0;
  if (c != L.frame_color || d != L.frame_dashed) {
    L.frame_color = c;
    L.frame_dashed = d;
    if (frameWin) ps_region_frame(frameWin, screen, NSMakeRect(L.x, L.y, L.core.w, L.core.h), c, d);
  }
}

static void tell(void) {
  frame_sync_color();
  int live_at = L.core.head_h + L.core.at;
  if (L.told_h == L.core.out_h && L.told_lost == L.core.lost && L.told_full == L.core.full &&
      L.told_paused == L.paused && L.told_pics == L.core.pictures && L.told_at == live_at &&
      L.told_dir == L.core.last_dir && L.core.pending_top == 0)
    return;
  L.told_h = L.core.out_h;
  L.told_lost = L.core.lost;
  L.told_full = L.core.full;
  L.told_paused = L.paused;
  L.told_pics = L.core.pictures;
  L.told_at = live_at;
  L.told_dir = L.core.last_dir;
  int top = L.core.pending_top;
  L.core.pending_top = 0;
  char json[192];
  int n = snprintf(json, sizeof json,
                   "{\"do\":\"long\",\"h\":%d,\"lost\":%d,\"full\":%d,\"paused\":%d,\"pics\":%d,\"dir\":%d,\"at\":%d,\"top\":%d}",
                   L.core.out_h, L.core.lost, L.core.full, L.paused, L.core.pictures, L.core.last_dir, live_at, top);
  mb_post("ps", json, (size_t)n, NULL, 0);
}

static moonbit_bytes_t bytes_of(const void *p, size_t n) {
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)n, 0);
  if (n) memcpy(b, p, n);
  return b;
}

@interface PSLongStream : NSObject <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, assign) uint64_t gen;
@end
static PSLongStream *taker;
static SCStream *stream;
static NSLock *latestLock;
static CVPixelBufferRef latest;
static uint64_t latestSeq;
static uint64_t streamGen;
static NSMutableSet<NSNumber *> *keptOut;
static uint64_t filterGen;
static uint64_t appliedFilterGen;

@implementation PSLongStream
- (void)stream:(SCStream *)s didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
  (void)s;
  if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sb))
    return;
  CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, NO);
  if (!att || CFArrayGetCount(att) == 0)
    return;
  NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(att, 0);
  if ([info[SCStreamFrameInfoStatus] integerValue] != SCFrameStatusComplete)
    return;
  CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
  if (!pb)
    return;
  [latestLock lock];
  if (self.gen == streamGen) {
    if (latest)
      CVPixelBufferRelease(latest);
    latest = CVPixelBufferRetain(pb);
    latestSeq++;
  }
  [latestLock unlock];
}
- (void)stream:(SCStream *)s didStopWithError:(NSError *)error {
  (void)s;
  NSLog(@"PinShot long stream stopped: %@", error);
}
@end

static void filter_then(void (^done)(SCContentFilter *, uint64_t)) {
  CGDirectDisplayID did = ps_display_id(screen);
  NSSet *out = [keptOut copy];
  uint64_t gen = filterGen;
  [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                             onScreenWindowsOnly:YES
                                               completionHandler:^(SCShareableContent *c, NSError *e) {
                                                 (void)e;
                                                 SCDisplay *display = nil;
                                                 for (SCDisplay *d in c.displays)
                                                   if (d.displayID == did)
                                                     display = d;
                                                 if (!display)
                                                   return;
                                                 NSMutableArray *ex = [NSMutableArray array];
                                                 for (SCWindow *w in c.windows)
                                                   if ([out containsObject:@(w.windowID)])
                                                     [ex addObject:w];
                                                 SCContentFilter *f = [[SCContentFilter alloc] initWithDisplay:display
                                                                                           excludingWindows:ex];
                                                 dispatch_async(dispatch_get_main_queue(), ^{ done(f, gen); });
                                               }];
}

static void stream_refilter(void);

static void stream_start(void) {
  if (!latestLock)
    latestLock = [NSLock new];
  [latestLock lock];
  streamGen++;
  uint64_t myGen = streamGen;
  [latestLock unlock];
  taker = [PSLongStream new];
  taker.gen = myGen;
  PSLongStream *me = taker;
  int x = L.x, y = L.y, w = L.core.w, h = L.core.h;
  filter_then(^(SCContentFilter *f, uint64_t fgen) {
    if (taker != me || !L.on)
      return;
    SCStreamConfiguration *c = [SCStreamConfiguration new];
    CGRect display = CGDisplayBounds(ps_display_id(screen));
    CGFloat k = screen.backingScaleFactor;
    c.sourceRect = CGRectMake((x - display.origin.x) / k, (y - display.origin.y) / k, w / k, h / k);
    c.width = w;
    c.height = h;
    c.scalesToFit = NO;
    c.minimumFrameInterval = CMTimeMake(1, 60);
    c.queueDepth = 4;
    c.pixelFormat = kCVPixelFormatType_32BGRA;
    c.colorSpaceName = kCGColorSpaceSRGB;
    c.showsCursor = NO;
#if defined(__MAC_14_0) && __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_14_0
    if (@available(macOS 14.0, *)) {
      c.captureResolution = SCCaptureResolutionBest;
    }
#endif
#if defined(__MAC_15_0) && __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_15_0
    if (@available(macOS 15.0, *)) {
      c.captureDynamicRange = SCCaptureDynamicRangeSDR;
    }
#endif
    stream = [[SCStream alloc] initWithFilter:f configuration:c delegate:me];
    NSError *err = nil;
    if (![stream addStreamOutput:me
                            type:SCStreamOutputTypeScreen
              sampleHandlerQueue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)
                           error:&err]) {
      stream = nil;
      return;
    }
    appliedFilterGen = fgen;
    [stream startCaptureWithCompletionHandler:^(NSError *e) {
      if (e)
        NSLog(@"PinShot long: %@", e);
    }];
    if (filterGen != appliedFilterGen)
      stream_refilter();
  });
}

static void stream_stop(void) {
  [latestLock lock];
  streamGen++;
  if (latest)
    CVPixelBufferRelease(latest);
  latest = NULL;
  [latestLock unlock];
  [stream stopCaptureWithCompletionHandler:nil];
  stream = nil;
  taker = nil;
}

static void stream_refilter(void) {
  if (!stream)
    return;
  SCStream *s = stream;
  filter_then(^(SCContentFilter *f, uint64_t fgen) {
    if (stream == s) {
      [s updateContentFilter:f completionHandler:nil];
      appliedFilterGen = fgen;
      if (filterGen != appliedFilterGen)
        stream_refilter();
    }
  });
}

static int take_now(void) {
  [latestLock lock];
  CVPixelBufferRef pb = latest && latestSeq != L.taken_seq ? CVPixelBufferRetain(latest) : NULL;
  uint64_t seq = latestSeq;
  [latestLock unlock];
  if (!pb)
    return 0;
  int ok = 0;
  if ((int)CVPixelBufferGetWidth(pb) == L.core.w && (int)CVPixelBufferGetHeight(pb) == L.core.h) {
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const uint8_t *bits = CVPixelBufferGetBaseAddress(pb);
    size_t pitch = CVPixelBufferGetBytesPerRow(pb);
    for (int y = 0; y < L.core.h; y++)
      memcpy(L.core.now + (size_t)y * (size_t)L.core.w * 4, bits + (size_t)y * pitch, (size_t)L.core.w * 4);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    L.taken_seq = seq;
    ok = 1;
  }
  CVPixelBufferRelease(pb);
  return ok;
}

static FILE *dump_log;
static void mac_dump(void *ctx, const char *what, int a, int b, int c, int d) {
  (void)ctx;
  const char *dir = getenv("PINSHOT_LONG_DUMP");
  if (!dir) return;
  if (!dump_log) {
    char path[1024];
    snprintf(path, sizeof path, "%s/long.log", dir);
    dump_log = fopen(path, "w");
  }
  if (dump_log)
    fprintf(dump_log, "%.0f %s %d %d %d %d (h %d)\n", now_ms() - L.begun, what, a, b, c, d, L.core.out_h),
        fflush(dump_log);
}

static void tick(void) {
  if (!L.on || L.paused || L.core.full) return;
  if (now_ms() - L.begun < SETTLE_MS) return;
  if (!take_now()) return;
  if (ls_step(&L.core)) tell();
}

static void taking_stop(void) {
  [timer invalidate];
  timer = nil;
  stream_stop();
  if (frameWin) {
    [keptOut removeObject:@(frameWin.windowNumber)];
    filterGen++;
    ps_region_frame_close(frameWin);
  }
  frameWin = nil;
}

static void let_go(void) {
  taking_stop();
  if (dump_log) fclose(dump_log);
  dump_log = NULL;
  canvas_release(L.canvas);
  ls_work_free(&L.core);
  screen = nil;
  [keptOut removeAllObjects];
  filterGen++;
  memset(&L, 0, sizeof L);
}

static void taking_begin(void) {
  if (!keptOut)
    keptOut = [NSMutableSet set];
  if (!(getenv("PINSHOT_TEST") && getenv("PINSHOT_TEST_CLOAKED"))) {
    frameWin = ps_region_frame(nil, screen, NSMakeRect(L.x, L.y, L.core.w, L.core.h), L.frame_color ?: 0x2F9BFF,
                               L.frame_dashed);
    if (!getenv("PINSHOT_LONG_SHOW"))
      frameWin.sharingType = NSWindowSharingNone;
    [keptOut addObject:@(frameWin.windowNumber)];
    filterGen++;
  }
  stream_start();
  timer = [NSTimer scheduledTimerWithTimeInterval:TICK_MS / 1000.0 repeats:YES block:^(NSTimer *t) { (void)t; tick(); }];
  timer.tolerance = 0.004;
}

int32_t ps_long_begin(int32_t x, int32_t y, int32_t w, int32_t h) {
  let_go();
  if (w < 16 || h < LS_LEAST_OVERLAP * 3) return 0;
  if (!CGPreflightScreenCaptureAccess()) return -1;
  NSScreen *on = nil;
  NSRect sp = NSZeroRect;
  for (NSScreen *s in NSScreen.screens) {
    NSRect p = ps_screen_pixels(s, s.frame);
    if (NSPointInRect(NSMakePoint(x + w / 2, y + h / 2), p)) {
      on = s;
      sp = p;
      break;
    }
  }
  if (!on) {
    on = ps_capture_screen() ?: ps_mouse_screen();
    sp = ps_screen_pixels(on, on.frame);
  }
  int mx = (int)NSMinX(sp), my = (int)NSMinY(sp), mr = (int)NSMaxX(sp), mb = (int)NSMaxY(sp);
  if (x < mx) w -= mx - x, x = mx;
  if (y < my) h -= my - y, y = my;
  if (x + w > mr) w = mr - x;
  if (y + h > mb) h = mb - y;
  if (w < 16 || h < LS_LEAST_OVERLAP * 3) return 0;
  screen = on;
  L.x = x, L.y = y;
  L.mx = mx, L.my = my, L.mw = mr - mx, L.mh = mb - my;
  int gutter = (int)(16.0 * on.backingScaleFactor + 0.5);
  L.core.w = w;
  L.core.h = h;
  L.core.hw = ls_compute_hw(w, gutter);
  L.core.strips = ls_compute_strips(L.core.hw);
  L.core.dump_fn = mac_dump;
  L.canvas = canvas_alloc(w);
  if (!L.canvas || !ls_work_alloc(&L.core)) {
    let_go();
    return 0;
  }
  L.core.base = L.canvas->base;
  ls_reset_state(&L.core);
  L.on = 1;
  L.told_h = -1;
  L.frame_color = 0x2F9BFF;
  L.begun = now_ms();
  taking_begin();
  return 1;
}

void ps_long_pause(int32_t on) {
  if (!L.on) return;
  int p = on ? 1 : 0;
  if (L.paused == p) return;
  L.paused = p;
  if (L.paused) {
    [timer invalidate];
    timer = nil;
    stream_stop();
  } else if (!L.core.full) {
    if (!stream) stream_start();
    if (!timer) {
      timer = [NSTimer scheduledTimerWithTimeInterval:TICK_MS / 1000.0 repeats:YES block:^(NSTimer *t) { (void)t; tick(); }];
      timer.tolerance = 0.004;
    }
  }
  tell();
}

void ps_long_reset(void) {
  if (!L.canvas || !ls_work_alloc(&L.core)) {
    let_go();
    return;
  }
  LongCanvas *fresh = canvas_alloc(L.core.w);
  if (!fresh) {
    let_go();
    return;
  }
  canvas_release(L.canvas);
  L.canvas = fresh;
  L.core.base = fresh->base;
  ls_reset_state(&L.core);
  L.paused = 0;
  L.told_h = -1;
  L.taken_seq = 0;
  if (!L.on) {
    L.on = 1;
    taking_begin();
  } else {
    if (!stream) stream_start();
    if (!timer) {
      timer = [NSTimer scheduledTimerWithTimeInterval:TICK_MS / 1000.0 repeats:YES block:^(NSTimer *t) { (void)t; tick(); }];
      timer.tolerance = 0.004;
    }
  }
  L.begun = now_ms() - SETTLE_MS;
  tell();
}

void ps_long_stop(void) {
  L.on = 0;
  taking_stop();
  ls_work_free(&L.core);
}

void ps_long_exclude(int32_t wid) {
  NSWindow *w = mb_app_window_of(wid);
  if (!w) return;
  mb_app_window_clear(wid);
  w.hasShadow = NO;
  if (!keptOut)
    keptOut = [NSMutableSet set];
  [keptOut addObject:@(w.windowNumber)];
  filterGen++;
  if (!getenv("PINSHOT_LONG_SHOW"))
    w.sharingType = NSWindowSharingNone;
  stream_refilter();
}

void ps_long_end(void) { let_go(); }

moonbit_bytes_t ps_long_info(void) {
  if (!L.core.out_h) return moonbit_make_bytes(0, 0);
  char s[96];
  int n = snprintf(s, sizeof s, "%d,%d,%d,%d,%d", L.core.w, L.core.out_h, L.core.pictures, L.core.lost, L.core.full);
  return bytes_of(s, (size_t)n);
}

void ps_long_preview_free(void) {}

moonbit_bytes_t ps_long_preview(int32_t box_w, int32_t box_h, int32_t from_row) {
  int from = 0, src_h = 0, pw = 0, ph = 0;
  if (!ls_preview_dims(&L.core, box_w, box_h, from_row, &from, &src_h, &pw, &ph)) return moonbit_make_bytes(0, 0);
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)(54 + (size_t)pw * (size_t)ph * 4), 0);
  ps_bmp_header(out, pw, ph);
  ls_preview_render(&L.core, from, src_h, pw, ph, out + 54);
  return out;
}

static NSData *encode_png_bgra(const uint8_t *px, int w, int h) {
  if (!px || w <= 0 || h <= 0) return nil;
  @autoreleasepool {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, px, (size_t)w * (size_t)h * 4, NULL);
    CGImageRef img = CGImageCreate(w, h, 8, 32, (size_t)w * 4, space,
                                   kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst, dp, NULL, NO,
                                   kCGRenderingIntentDefault);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(space);
    NSMutableData *png = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)png, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    BOOL ok = NO;
    if (dst && img) {
      CGImageDestinationAddImage(dst, img, NULL);
      ok = CGImageDestinationFinalize(dst);
    }
    if (dst) CFRelease(dst);
    if (img) CGImageRelease(img);
    return ok ? png : nil;
  }
}

moonbit_bytes_t ps_long_png(void) {
  if (!L.core.out_h || !L.core.out) return moonbit_make_bytes(0, 0);
  NSData *png = encode_png_bgra(L.core.out, L.core.w, L.core.out_h);
  return png ? ps_data(png) : moonbit_make_bytes(0, 0);
}

int32_t ps_long_export(int32_t req_id) {
  if (!L.canvas || !L.core.out || L.core.out_h <= 0) return 0;
  ps_long_stop();
  LongCanvas *cv = L.canvas;
  __sync_add_and_fetch(&cv->refs, 1);
  size_t off = (size_t)(L.core.out - cv->base);
  int w = L.core.w;
  int h = L.core.out_h;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSData *png = encode_png_bgra(cv->base + off, w, h);
    int ok = png && png.length > 0 ? 1 : 0;
    char json[128];
    int n = snprintf(json, sizeof json, "{\"do\":\"long-png\",\"id\":%d,\"w\":%d,\"h\":%d,\"ok\":%d}", req_id, w, h,
                     ok);
    mb_post("ps", json, (size_t)n, ok ? (const uint8_t *)png.bytes : NULL, ok ? (size_t)png.length : 0);
    canvas_release(cv);
  });
  return 1;
}
