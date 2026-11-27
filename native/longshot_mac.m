#import "mac_platform.h"
#import <ImageIO/ImageIO.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sys/mman.h>

extern void mb_post(const char *channel, const char *json, size_t len, const uint8_t *bytes, size_t blen);
NSWindow *ps_region_frame(NSWindow *w, NSScreen *s, NSRect pixels, int rgb, int dashed);
void ps_region_frame_close(NSWindow *w);

#define TICK_MS 16
#define MOST_ROWS 30000
#define LEAST_OVERLAP 24
#define FIXED_MOST 3
#define SETTLE_MS 180
#define STRIPS_MOST 8
#define STRIP_LEAST 64
#define PROF_W 64
#define LOOSE_MOST 6.0

static struct {
  int on;
  int x, y, w, h;
  int mx, my, mw, mh;
  uint8_t *base;
  size_t base_len;
  int first;
  uint8_t *out;
  int out_h;
  int foot_h;
  int head_h;
  int at;
  int strips;
  int hw;
  uint8_t *ref;
  uint64_t *ref_hash;
  uint8_t *ref_flat;
  uint8_t *now;
  uint64_t *now_hash;
  uint8_t *now_flat;
  uint8_t *ref_prof, *now_prof;
  int ref_prof_ok, now_prof_ok;
  int pictures;
  int lost;
  int full;
  int paused;
  int last_dir;
  int pending_top;
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

static int frame_want_color(void) {
  if (L.paused) return 0x9EA4B2;
  if (L.full || L.lost) return 0xF5A524;
  return 0x2F9BFF;
}

static void frame_sync_color(void) {
  int c = frame_want_color();
  int d = L.paused ? 1 : 0;
  if (c != L.frame_color || d != L.frame_dashed) {
    L.frame_color = c;
    L.frame_dashed = d;
    if (frameWin) ps_region_frame(frameWin, screen, NSMakeRect(L.x, L.y, L.w, L.h), c, d);
  }
}

static void tell(void) {
  frame_sync_color();
  int live_at = L.head_h + L.at;
  if (L.told_h == L.out_h && L.told_lost == L.lost && L.told_full == L.full && L.told_paused == L.paused &&
      L.told_pics == L.pictures && L.told_at == live_at && L.told_dir == L.last_dir && L.pending_top == 0)
    return;
  L.told_h = L.out_h, L.told_lost = L.lost, L.told_full = L.full;
  L.told_paused = L.paused, L.told_pics = L.pictures, L.told_at = live_at, L.told_dir = L.last_dir;
  int top = L.pending_top;
  L.pending_top = 0;
  char json[192];
  int n = snprintf(json, sizeof json,
                   "{\"do\":\"long\",\"h\":%d,\"lost\":%d,\"full\":%d,\"paused\":%d,\"pics\":%d,\"dir\":%d,\"at\":%d,\"top\":%d}",
                   L.out_h, L.lost, L.full, L.paused, L.pictures, L.last_dir, live_at, top);
  mb_post("ps", json, (size_t)n, NULL, 0);
}

static moonbit_bytes_t bytes_of(const void *p, size_t n) {
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)n, 0);
  if (n) memcpy(b, p, n);
  return b;
}

static int out_room_at(int lo, int hi) {
  return lo >= 0 && hi <= MOST_ROWS * 2 && hi - lo <= MOST_ROWS;
}

static int out_room(int rows) {
  if (rows > MOST_ROWS) return 0;
  return out_room_at(L.first, L.first + rows);
}

static void out_at(int first) {
  L.first = first;
  L.out = L.base + (size_t)first * L.w * 4;
}

static void out_add(int from, int to) {
  if (to <= from) return;
  int n = to - from;
  if (L.out_h + n > MOST_ROWS) {
    n = MOST_ROWS - L.out_h;
    L.full = 1;
  }
  if (n <= 0 || !out_room(L.out_h + n)) {
    L.full = 1;
    return;
  }
  memcpy(L.out + (size_t)L.out_h * L.w * 4, L.now + (size_t)from * L.w * 4, (size_t)n * L.w * 4);
  L.out_h += n;
}

static void out_put_at(int at, int from, int to) {
  if (to <= from) return;
  int n = to - from;
  if (L.out_h + n > MOST_ROWS) {
    n = MOST_ROWS - L.out_h;
    L.full = 1;
  }
  if (n <= 0 || !out_room_at(L.first - n, L.first + L.out_h)) {
    L.full = 1;
    return;
  }
  size_t row = (size_t)L.w * 4;
  uint8_t *old = L.out;
  out_at(L.first - n);
  memmove(L.out, old, (size_t)at * row);
  memcpy(L.out + (size_t)at * row, L.now + (size_t)(to - n) * row, (size_t)n * row);
  L.out_h += n;
}

static void hash_rows(const uint8_t *px, uint64_t *hash, uint8_t *flat) {
  for (int s = 0; s < L.strips; s++) {
    int x0 = s * L.hw / L.strips, x1 = (s + 1) * L.hw / L.strips;
    for (int y = 0; y < L.h; y++) {
      const uint32_t *r = (const uint32_t *)(px + (size_t)y * L.w * 4);
      uint64_t hv = 1469598103934665603ULL;
      uint32_t first = r[x0] & 0xFFFFFF;
      int one = 1;
      for (int x = x0; x < x1; x++) {
        uint32_t c = r[x] & 0xFFFFFF;
        if (c != first) one = 0;
        hv = (hv ^ c) * 1099511628211ULL;
      }
      hash[s * L.h + y] = hv;
      flat[s * L.h + y] = (uint8_t)one;
    }
  }
}

static void profile_of(const uint8_t *img, uint8_t *prof) {
  for (int y = 0; y < L.h; y++) {
    const uint8_t *row = img + (size_t)y * L.w * 4;
    for (int c = 0; c < PROF_W; c++) {
      int x0 = c * L.hw / PROF_W, x1 = (c + 1) * L.hw / PROF_W;
      unsigned sum = 0, n = 0;
      for (int x = x0; x < x1; x += 2) {
        const uint8_t *px = row + (size_t)x * 4;
        sum += (px[0] + px[1] * 5u + px[2] * 2u) >> 3;
        n++;
      }
      prof[(size_t)y * PROF_W + c] = (uint8_t)(n ? sum / n : 0);
    }
  }
}

static void profiles_made(void) {
  if (!L.now_prof_ok) profile_of(L.now, L.now_prof), L.now_prof_ok = 1;
  if (!L.ref_prof_ok) profile_of(L.ref, L.ref_prof), L.ref_prof_ok = 1;
}

static int prof_row_diff(const uint8_t *a, int ya, const uint8_t *b, int yb) {
  const uint8_t *p = a + (size_t)ya * PROF_W, *q = b + (size_t)yb * PROF_W;
  int d = 0;
  for (int c = 0; c < PROF_W; c++) d += p[c] > q[c] ? p[c] - q[c] : q[c] - p[c];
  return d;
}

static int prof_marked(int y) {
  const uint8_t *p = L.now_prof + (size_t)y * PROF_W;
  int lo = 255, hi = 0;
  for (int c = 0; c < PROF_W; c++) {
    if (p[c] < lo) lo = p[c];
    if (p[c] > hi) hi = p[c];
  }
  return hi - lo >= 8;
}

static double prof_band(int d, int top, int band, int step, int up) {
  long sum = 0, n = 0;
  for (int y = top; y < top + band - d; y += step) {
    int yn = up ? y + d : y, yr = up ? y : y + d;
    if (!prof_marked(yn)) continue;
    sum += prof_row_diff(L.now_prof, yn, L.ref_prof, yr);
    n++;
  }
  return n * step >= LEAST_OVERLAP ? (double)sum / (n * PROF_W) : 1e9;
}

static void still_rows(int *head, int *foot) {
  profiles_made();
  int most = L.h / FIXED_MOST, top = 0, bot = 0;
  int still_most = (int)(PROF_W * 3);
  while (top < most && prof_row_diff(L.now_prof, top, L.ref_prof, top) <= still_most) top++;
  while (bot < most && prof_row_diff(L.now_prof, L.h - 1 - bot, L.ref_prof, L.h - 1 - bot) <= still_most) bot++;
  *head = top;
  *foot = bot;
}

static int loose_shift(int up, int *bot, int *head) {
  int top = 0, foot = 0;
  still_rows(&top, &foot);
  *bot = foot;
  *head = top;
  int band = L.h - top - foot;
  if (band < LEAST_OVERLAP * 2) return 0;
  double at0 = prof_band(0, top, band, 4, up);
  int best = 0, reach = band - (band / 5 > LEAST_OVERLAP * 2 ? band / 5 : LEAST_OVERLAP * 2);
  double best_v = 1e9;
  for (int d = 2; d <= reach; d += 2) {
    double v = prof_band(d, top, band, 4, up);
    if (v < best_v) best_v = v, best = d;
  }
  if (!best) return 0;
  int fine = best;
  double fine_v = 1e9;
  for (int d = best - 3; d <= best + 3; d++) {
    if (d < 1 || d > reach) continue;
    double v = prof_band(d, top, band, 2, up);
    if (v < fine_v) fine_v = v, fine = d;
  }
  if (fine_v > LOOSE_MOST || fine_v * 3.0 > at0) return 0;
  return fine;
}

@interface PSLongStream : NSObject <SCStreamOutput, SCStreamDelegate>
@end
static PSLongStream *taker;
static SCStream *stream;
static NSLock *latestLock;
static CVPixelBufferRef latest;
static uint64_t latestSeq;
static NSMutableSet<NSNumber *> *keptOut;

@implementation PSLongStream
- (void)stream:(SCStream *)s didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
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
  if (latest)
    CVPixelBufferRelease(latest);
  latest = CVPixelBufferRetain(pb);
  latestSeq++;
  [latestLock unlock];
}
- (void)stream:(SCStream *)s didStopWithError:(NSError *)error {
  NSLog(@"PinShot long stream stopped: %@", error);
}
@end

static void filter_then(void (^done)(SCContentFilter *)) {
  CGDirectDisplayID id = ps_display_id(screen);
  NSSet *out = [keptOut copy];
  [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                             onScreenWindowsOnly:YES
                                               completionHandler:^(SCShareableContent *c, NSError *e) {
                                                 SCDisplay *display = nil;
                                                 for (SCDisplay *d in c.displays)
                                                   if (d.displayID == id)
                                                     display = d;
                                                 if (!display)
                                                   return;
                                                 NSMutableArray *ex = [NSMutableArray array];
                                                 for (SCWindow *w in c.windows)
                                                   if ([out containsObject:@(w.windowID)])
                                                     [ex addObject:w];
                                                 SCContentFilter *f = [[SCContentFilter alloc] initWithDisplay:display
                                                                                           excludingWindows:ex];
                                                 dispatch_async(dispatch_get_main_queue(), ^{ done(f); });
                                               }];
}

static void stream_start(void) {
  if (!latestLock)
    latestLock = [NSLock new];
  taker = [PSLongStream new];
  PSLongStream *me = taker;
  int x = L.x, y = L.y, w = L.w, h = L.h;
  filter_then(^(SCContentFilter *f) {
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
    stream = [[SCStream alloc] initWithFilter:f configuration:c delegate:me];
    NSError *err = nil;
    if (![stream addStreamOutput:me
                            type:SCStreamOutputTypeScreen
              sampleHandlerQueue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)
                           error:&err]) {
      stream = nil;
      return;
    }
    [stream startCaptureWithCompletionHandler:^(NSError *e) {
      if (e)
        NSLog(@"PinShot long: %@", e);
    }];
  });
}

static void stream_stop(void) {
  [stream stopCaptureWithCompletionHandler:nil];
  stream = nil;
  taker = nil;
  [latestLock lock];
  if (latest)
    CVPixelBufferRelease(latest);
  latest = NULL;
  [latestLock unlock];
}

static void stream_refilter(void) {
  if (!stream)
    return;
  SCStream *s = stream;
  filter_then(^(SCContentFilter *f) {
    if (stream == s)
      [s updateContentFilter:f completionHandler:nil];
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
  if ((int)CVPixelBufferGetWidth(pb) == L.w && (int)CVPixelBufferGetHeight(pb) == L.h) {
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const uint8_t *bits = CVPixelBufferGetBaseAddress(pb);
    size_t pitch = CVPixelBufferGetBytesPerRow(pb);
    for (int y = 0; y < L.h; y++) memcpy(L.now + (size_t)y * L.w * 4, bits + (size_t)y * pitch, (size_t)L.w * 4);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    L.taken_seq = seq;
    ok = 1;
  }
  CVPixelBufferRelease(pb);
  return ok;
}

typedef struct {
  int still;
  int down, up;
  int bot;
} Strip;

static int shift_of(const uint64_t *a, const uint64_t *b, const uint8_t *flat, int top, int bot) {
  int band = L.h - top - bot;
  if (band < LEAST_OVERLAP * 2) return 0;
  int best = 0, best_score = 0;
  for (int d = 1; d <= band - LEAST_OVERLAP; d++) {
    int agree = 0, differ = 0, lines = band - d;
    for (int y = top; y < top + lines; y++) {
      if (a[y] == b[y + d]) {
        if (!flat[y]) agree++;
      } else if (++differ * 20 > lines) {
        break;
      }
    }
    if (differ * 20 > lines) continue;
    if (agree < 8 || agree * 16 < lines) continue;
    if (agree > best_score) best_score = agree, best = d;
  }
  return best;
}

static Strip strip_of(int s) {
  Strip r = {0, 0, 0, 0};
  const uint64_t *ref = L.ref_hash + s * L.h, *now = L.now_hash + s * L.h;
  int differ = 0;
  for (int y = 0; y < L.h; y++) differ += now[y] != ref[y];
  if (differ * 20 <= L.h) {
    r.still = 1;
    return r;
  }
  int most = L.h / FIXED_MOST, top = 0;
  while (top < most && now[top] == ref[top]) top++;
  while (r.bot < most && now[L.h - 1 - r.bot] == ref[L.h - 1 - r.bot]) r.bot++;
  r.down = shift_of(now, ref, L.now_flat + s * L.h, top, r.bot);
  if (!r.down) r.up = shift_of(ref, now, L.ref_flat + s * L.h, top, r.bot);
  return r;
}

static int agreed(const Strip *st, int up, int *bot) {
  int moving = 0, best = 0, best_n = 0, second_n = 0;
  for (int s = 0; s < L.strips; s++) moving += !st[s].still;
  for (int s = 0; s < L.strips; s++) {
    int d = up ? st[s].up : st[s].down, n = 0, seen = 0;
    if (!d) continue;
    for (int t = 0; t < s && !seen; t++) seen = (up ? st[t].up : st[t].down) == d;
    if (seen) continue;
    for (int t = s; t < L.strips; t++) n += (up ? st[t].up : st[t].down) == d;
    if (n > best_n) second_n = best_n, best_n = n, best = d;
    else if (n > second_n) second_n = n;
  }
  if (!best || best_n < (moving < 2 ? moving : 2) || best_n <= second_n || best_n * 3 < moving) return 0;
  *bot = L.h;
  for (int s = 0; s < L.strips; s++)
    if ((up ? st[s].up : st[s].down) == best && st[s].bot < *bot) *bot = st[s].bot;
  return best;
}

static FILE *dump_log;
static void dump(const char *what, int a, int b, int c, int d) {
  const char *dir = getenv("PINSHOT_LONG_DUMP");
  if (!dir) return;
  if (!dump_log) {
    char path[1024];
    snprintf(path, sizeof path, "%s/long.log", dir);
    dump_log = fopen(path, "w");
  }
  if (dump_log)
    fprintf(dump_log, "%.0f %s %d %d %d %d (h %d)\n", now_ms() - L.begun, what, a, b, c, d, L.out_h), fflush(dump_log);
}

static void tick(void) {
  if (!L.on || L.paused || L.full) return;
  if (now_ms() - L.begun < SETTLE_MS) return;
  if (!take_now()) return;
  hash_rows(L.now, L.now_hash, L.now_flat);
  L.now_prof_ok = 0;
  if (!L.pictures) {
    dump("first", 0, 0, 0, 0);
    out_add(0, L.h);
    L.foot_h = 0;
  } else {
    Strip st[STRIPS_MOST];
    int moving = 0;
    for (int s = 0; s < L.strips; s++) {
      st[s] = strip_of(s);
      moving += !st[s].still;
    }
    int bot = 0, head = 0, d = 0, up = 0;
    d = agreed(st, 0, &bot);
    if (!d) {
      int u_bot = 0, u = agreed(st, 1, &u_bot);
      if (u) d = u, up = 1, bot = u_bot;
    }
    if (!d && moving) {
      d = loose_shift(0, &bot, &head);
      if (d) {
        dump("loose", moving, d, bot, 0);
      } else {
        d = loose_shift(1, &bot, &head);
        if (d) up = 1, dump("loose-up", moving, d, head, 0);
      }
    }
    if (!d) {
      int still = L.strips - moving;
      L.lost = still < moving;
      dump(L.lost ? "lost" : "still", moving, still, 0, 0);
      tell();
      return;
    }
    if (L.pictures == 1) {
      if (!head) {
        int b2 = 0;
        still_rows(&head, &b2);
        if (!bot) bot = b2;
      }
      L.head_h = head;
      L.foot_h = bot;
      L.at = 0;
    }
    int band = L.h - L.head_h - L.foot_h;
    int laid = L.out_h - L.head_h - L.foot_h;
    if (up) {
      dump("moved-up", moving, d, L.at, laid);
      L.at -= d;
      if (L.at < 0) {
        int n = -L.at;
        if (n > band) n = band;
        int before = L.out_h;
        out_put_at(L.head_h, L.head_h, L.head_h + n);
        int added = L.out_h - before;
        if (added > 0) {
          L.last_dir = -1;
          L.pending_top += added;
        }
        L.at = 0;
      }
    } else {
      dump("moved", moving, d, L.at, laid);
      L.at += d;
      int past = L.at + band - laid;
      if (past > 0) {
        if (past > band) past = band;
        int before = L.out_h;
        L.out_h -= L.foot_h;
        out_add(L.h - L.foot_h - past, L.h);
        if (L.out_h > before) L.last_dir = 1;
        L.at = L.out_h - L.head_h - L.foot_h - band;
      }
    }
  }
  L.lost = 0;
  L.pictures++;
  uint8_t *p = L.ref;
  L.ref = L.now, L.now = p;
  uint64_t *hp = L.ref_hash;
  L.ref_hash = L.now_hash, L.now_hash = hp;
  uint8_t *fp = L.ref_flat;
  L.ref_flat = L.now_flat, L.now_flat = fp;
  uint8_t *pp = L.ref_prof;
  L.ref_prof = L.now_prof, L.now_prof = pp;
  int pok = L.ref_prof_ok;
  L.ref_prof_ok = L.now_prof_ok, L.now_prof_ok = pok;
  tell();
}

static void work_let_go(void) {
  free(L.ref), free(L.now), free(L.ref_hash), free(L.now_hash), free(L.ref_flat), free(L.now_flat);
  free(L.ref_prof), free(L.now_prof);
  L.ref = L.now = L.ref_flat = L.now_flat = L.ref_prof = L.now_prof = NULL;
  L.ref_hash = L.now_hash = NULL;
}

static void taking_stop(void) {
  [timer invalidate];
  timer = nil;
  stream_stop();
  if (frameWin) {
    [keptOut removeObject:@(frameWin.windowNumber)];
    ps_region_frame_close(frameWin);
  }
  frameWin = nil;
}

static void let_go(void) {
  taking_stop();
  if (dump_log) fclose(dump_log);
  dump_log = NULL;
  if (L.base) munmap(L.base, L.base_len);
  work_let_go();
  screen = nil;
  [keptOut removeAllObjects];
  memset(&L, 0, sizeof L);
}

static int work_made(void) {
  if (L.ref) return 1;
  size_t frame = (size_t)L.w * L.h * 4, rows = (size_t)L.strips * L.h;
  L.ref = (uint8_t *)malloc(frame), L.now = (uint8_t *)malloc(frame);
  L.ref_hash = (uint64_t *)malloc(rows * sizeof(uint64_t)), L.now_hash = (uint64_t *)malloc(rows * sizeof(uint64_t));
  L.ref_flat = (uint8_t *)malloc(rows), L.now_flat = (uint8_t *)malloc(rows);
  L.ref_prof = (uint8_t *)malloc((size_t)L.h * PROF_W), L.now_prof = (uint8_t *)malloc((size_t)L.h * PROF_W);
  L.ref_prof_ok = L.now_prof_ok = 0;
  return L.ref && L.now && L.ref_hash && L.now_hash && L.ref_flat && L.now_flat && L.ref_prof && L.now_prof;
}

static int base_made(void) {
  L.base_len = (size_t)MOST_ROWS * 2 * L.w * 4;
  void *p = mmap(NULL, L.base_len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  L.base = p == MAP_FAILED ? NULL : (uint8_t *)p;
  return L.base != NULL;
}

static void taking_begin(void) {
  if (!keptOut)
    keptOut = [NSMutableSet set];
  if (!(getenv("PINSHOT_TEST") && getenv("PINSHOT_TEST_CLOAKED"))) {
    frameWin = ps_region_frame(nil, screen, NSMakeRect(L.x, L.y, L.w, L.h), L.frame_color ?: 0x2F9BFF, L.frame_dashed);
    if (!getenv("PINSHOT_LONG_SHOW"))
      frameWin.sharingType = NSWindowSharingNone;
    [keptOut addObject:@(frameWin.windowNumber)];
  }
  stream_start();
  timer = [NSTimer scheduledTimerWithTimeInterval:TICK_MS / 1000.0 repeats:YES block:^(NSTimer *t) { tick(); }];
  timer.tolerance = 0.004;
}

int32_t ps_long_begin(int32_t x, int32_t y, int32_t w, int32_t h) {
  let_go();
  if (w < 16 || h < LEAST_OVERLAP * 3) return 0;
  if (!CGPreflightScreenCaptureAccess()) return 0;
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
  if (w < 16 || h < LEAST_OVERLAP * 3) return 0;
  screen = on;
  L.x = x, L.y = y, L.w = w, L.h = h;
  L.mx = mx, L.my = my, L.mw = mr - mx, L.mh = mb - my;
  int gutter = (int)(16 * on.backingScaleFactor);
  L.hw = w - (w >= gutter * 8 ? gutter : 0);
  L.strips = L.hw / STRIP_LEAST < 2 ? 1 : (L.hw / STRIP_LEAST > STRIPS_MOST ? STRIPS_MOST : L.hw / STRIP_LEAST);
  if (!base_made() || !work_made()) {
    let_go();
    return 0;
  }
  out_at(MOST_ROWS);
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
  } else if (!L.full) {
    if (!stream) stream_start();
    if (!timer) {
      timer = [NSTimer scheduledTimerWithTimeInterval:TICK_MS / 1000.0 repeats:YES block:^(NSTimer *t) { tick(); }];
      timer.tolerance = 0.004;
    }
  }
  tell();
}

void ps_long_reset(void) {
  if (!L.base || !work_made()) return;
  munmap(L.base, L.base_len);
  if (!base_made()) return;
  out_at(MOST_ROWS);
  L.out_h = 0, L.foot_h = 0, L.head_h = 0, L.at = 0;
  L.pictures = 0, L.lost = 0, L.full = 0, L.paused = 0, L.last_dir = 0, L.pending_top = 0;
  L.told_h = -1;
  L.taken_seq = 0;
  if (!L.on) {
    L.on = 1;
    taking_begin();
  } else {
    if (!stream) stream_start();
    if (!timer) {
      timer = [NSTimer scheduledTimerWithTimeInterval:TICK_MS / 1000.0 repeats:YES block:^(NSTimer *t) { tick(); }];
      timer.tolerance = 0.004;
    }
  }
  L.begun = now_ms() - SETTLE_MS;
  tell();
}

void ps_long_stop(void) {
  L.on = 0;
  taking_stop();
  work_let_go();
}

void ps_long_exclude(int32_t wid) {
  NSWindow *w = mb_app_window_of(wid);
  if (!w) return;
  mb_app_window_clear(wid);
  w.hasShadow = NO;
  if (!keptOut)
    keptOut = [NSMutableSet set];
  [keptOut addObject:@(w.windowNumber)];
  if (!getenv("PINSHOT_LONG_SHOW"))
    w.sharingType = NSWindowSharingNone;
  stream_refilter();
}

void ps_long_end(void) { let_go(); }

moonbit_bytes_t ps_long_info(void) {
  if (!L.out_h) return moonbit_make_bytes(0, 0);
  char s[96];
  int n = snprintf(s, sizeof s, "%d,%d,%d,%d,%d", L.w, L.out_h, L.pictures, L.lost, L.full);
  return bytes_of(s, (size_t)n);
}

void ps_long_preview_free(void) {}

moonbit_bytes_t ps_long_preview(int32_t box_w, int32_t box_h, int32_t from_row) {
  if (!L.out_h || box_w <= 0 || box_h <= 0) return moonbit_make_bytes(0, 0);
  double k = (double)box_w / L.w;
  if (k > 1.0) k = 1.0;
  int vis_rows = (int)((double)box_h / k + 0.5);
  if (vis_rows < 1) vis_rows = 1;
  int max_from = L.out_h > vis_rows ? L.out_h - vis_rows : 0;
  int from = from_row < 0 ? 0 : (from_row > max_from ? max_from : from_row);
  int src_h = L.out_h - from;
  if (src_h > vis_rows) src_h = vis_rows;
  int pw = (int)(L.w * k + 0.5), ph = (int)(src_h * k + 0.5);
  if (pw < 1) pw = 1;
  if (ph < 1) ph = 1;
  if (ph > box_h) ph = box_h;
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)(54 + (size_t)pw * (size_t)ph * 4), 0);
  ps_bmp_header(out, pw, ph);
  uint8_t *p = out + 54;
  for (int y = 0; y < ph; y++) {
    int y0 = from + (int)((double)y * src_h / ph), y1 = from + (int)((double)(y + 1) * src_h / ph);
    if (y1 <= y0) y1 = y0 + 1;
    if (y1 > L.out_h) y1 = L.out_h;
    if (y0 >= L.out_h) y0 = L.out_h - 1;
    int ys = (y1 - y0) > 4 ? (y1 - y0) / 4 : 1;
    for (int x = 0; x < pw; x++) {
      int x0 = (int)((double)x * L.w / pw), x1 = (int)((double)(x + 1) * L.w / pw);
      if (x1 <= x0) x1 = x0 + 1;
      int xs = (x1 - x0) > 4 ? (x1 - x0) / 4 : 1;
      unsigned bb = 0, g = 0, r = 0, n = 0;
      for (int yy = y0; yy < y1; yy += ys) {
        const uint8_t *s = L.out + ((size_t)yy * L.w + x0) * 4;
        for (int xx = x0; xx < x1; xx += xs, s += 4 * xs) bb += s[0], g += s[1], r += s[2], n++;
      }
      uint8_t *d = p + ((size_t)y * pw + x) * 4;
      d[0] = (uint8_t)(bb / n), d[1] = (uint8_t)(g / n), d[2] = (uint8_t)(r / n), d[3] = 255;
    }
  }
  return out;
}

moonbit_bytes_t ps_long_png(void) {
  if (!L.out_h) return moonbit_make_bytes(0, 0);
  @autoreleasepool {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, L.out, (size_t)L.w * L.out_h * 4, NULL);
    CGImageRef img = CGImageCreate(L.w, L.out_h, 8, 32, (size_t)L.w * 4, space,
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
    return ok ? ps_data(png) : moonbit_make_bytes(0, 0);
  }
}
