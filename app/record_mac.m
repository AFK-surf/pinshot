// Area screen recording and its export (the Mac side of record_win.cpp and record_draw_win.cpp, the same calls and the
// same "rec" events on the channel "ps", so record.mbt's panel is the same on both):
// 1. The region framed by a window of its own (its rounded border drawn with a soft glow; in the Ready phase its edges
//    and corners drag the region bigger or smaller, told as {"do":"rec-rect"}; once recording, it lets every click
//    through: red, dashed amber while paused). It and the panel are kept out of what is recorded.
// 2. The region recorded by ScreenCaptureKit (cropped to it on the display, the cursor as asked, the system's sound
//    without PinShot's own) into a temporary MP4: hardware HEVC where it is (every Apple silicon Mac), else H.264, at
//    the "Original" quality's bitrate (record.mbt's rec_target_bps), with AAC sound.
// 3. Clicks' ripples and the keys pressed shown over the region (a click-through window of their own that is recorded
//    with it); keys only where PinShot may watch them (Accessibility), clicks always.
// 4. The recording exported as asked (ps_rec_export): MP4 HEVC or H.264 at a quality and size (copied as it is where
//    nothing changes), or an animated GIF; its progress told, it called off at any point.
//
// Nothing of it exists until a recording panel asks: no stream, no encoder, no window, no event monitor.
#import "mac_platform.h"
#import <AVFoundation/AVFoundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <VideoToolbox/VideoToolbox.h>
#import <stdatomic.h>

extern void mb_post(const char *, const char *, size_t, const uint8_t *, size_t);
extern void mb_app_window_clear(int wid);

// ---- what is told ----

static void recPost(NSString *state, int64_t ms, int frames, uint64_t bytes, uint64_t orig, int pct, int audio,
                    NSString *codec, NSString *path, NSString *err) {
  NSDictionary *o = @{
    @"do" : @"rec",
    @"state" : state,
    @"ms" : @(ms),
    @"frames" : @(frames),
    @"bytes" : @(bytes),
    @"orig" : @(orig),
    @"pct" : @(pct),
    @"audio" : @(audio),
    @"codec" : codec ?: @"",
    @"path" : path ?: @"",
    @"err" : err ?: @""
  };
  NSData *json = [NSJSONSerialization dataWithJSONObject:o options:0 error:nil];
  mb_post("ps", json.bytes, json.length, NULL, 0);
}

static NSString *utf8(moonbit_bytes_t b) {
  int n = (int)Moonbit_array_length(b);
  while (n > 0 && b[n - 1] == 0)
    n--;
  return [[NSString alloc] initWithBytes:b length:n encoding:NSUTF8StringEncoding] ?: @"";
}

static uint64_t fileSize(NSString *path) {
  return [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileSize];
}

static BOOL testing(void) {
  const char *t = getenv("PINSHOT_TEST");
  return t && t[0] && strcmp(t, "0") != 0;
}

// A file put on the clipboard as a file (Finder pastes it, chats attach it); a test run writes its path instead.
static void copyFile(NSString *path) {
  const char *copyTo = getenv("PINSHOT_TEST_COPY");
  if (copyTo && copyTo[0]) {
    [path writeToFile:@(copyTo) atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return;
  }
  if (testing())
    return;
  dispatch_async(dispatch_get_main_queue(), ^{
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    [board clearContents];
    [board writeObjects:@[ [NSURL fileURLWithPath:path] ]];
  });
}

// The bitrate record.mbt estimates sizes with (rec_target_bps): codec 0 HEVC, 1 H.264; quality 0 Original .. 3.
static double targetBps(int codec, int qual, int w, int h, int fps) {
  double ef = fps > 30 ? 30.0 + (fps - 30) * 0.35 : fps;
  double px = (double)w * h * ef;
  int qi = qual < 0 ? 0 : qual > 3 ? 3 : qual;
  double hiMul = fps > 60 ? 1.5 : 1.0;
  static const double bppH[] = {0.075, 0.048, 0.024, 0.011}, loH[] = {900000, 550000, 280000, 150000},
                      hiH[] = {16000000, 8000000, 3500000, 1500000};
  static const double bpp4[] = {0.115, 0.072, 0.038, 0.018}, lo4[] = {1300000, 800000, 420000, 220000},
                      hi4[] = {24000000, 12000000, 5200000, 2200000};
  double v = px * (codec == 0 ? bppH[qi] : bpp4[qi]);
  double lo = codec == 0 ? loH[qi] : lo4[qi], hi = (codec == 0 ? hiH[qi] : hi4[qi]) * hiMul;
  return v < lo ? lo : v > hi ? hi : v;
}

// The size an export is made at (record_win.cpp's compute_scaled_dims): 1..99 a percent, >100 the longest edge.
static void scaledDims(int sw, int sh, int param, int *ow, int *oh) {
  *ow = sw;
  *oh = sh;
  if (param > 0 && param < 100) {
    double k = param / 100.0;
    *ow = MAX(16, MIN(sw, ((int)(sw * k + 0.5)) & ~1));
    *oh = MAX(16, MIN(sh, ((int)(sh * k + 0.5)) & ~1));
  } else if (param > 100 && (sw > param || sh > param)) {
    double k = (double)param / (sw > sh ? sw : sh);
    *ow = MAX(16, ((int)(sw * k + 0.5)) & ~1);
    *oh = MAX(16, ((int)(sh * k + 0.5)) & ~1);
  }
}

// The panel's preview (record_win.cpp's build_preview_bmp): the last frame cover-cropped into a 316×368 BMP with a
// dark scrim at its bottom, under the words the panel puts there.
static NSData *previewBmp(CVPixelBufferRef pb) {
  if (!pb || CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_32BGRA)
    return nil;
  CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  const uint8_t *px = CVPixelBufferGetBaseAddress(pb);
  int w = (int)CVPixelBufferGetWidth(pb), h = (int)CVPixelBufferGetHeight(pb);
  size_t pitch = CVPixelBufferGetBytesPerRow(pb);
  const int pw = 316, ph = 368;
  double srcAsp = (double)w / h, dstAsp = (double)pw / ph;
  int cx0 = 0, cy0 = 0, cw = w, ch = h;
  if (srcAsp > dstAsp) {
    cw = MAX(1, MIN(w, (int)(h * dstAsp + 0.5)));
    cx0 = (w - cw) / 2;
  } else {
    ch = MAX(1, MIN(h, (int)(w / dstAsp + 0.5)));
    cy0 = (h - ch) / 2;
  }
  NSMutableData *out = [NSMutableData dataWithLength:54 + (size_t)pw * ph * 4];
  uint8_t *hdr = out.mutableBytes;
  uint32_t fsz = (uint32_t)out.length, off = 54, hsize = 40;
  int32_t bw = pw, bh = -ph;
  uint16_t planes = 1, bits = 32;
  hdr[0] = 'B';
  hdr[1] = 'M';
  memcpy(hdr + 2, &fsz, 4);
  memcpy(hdr + 10, &off, 4);
  memcpy(hdr + 14, &hsize, 4);
  memcpy(hdr + 18, &bw, 4);
  memcpy(hdr + 22, &bh, 4);
  memcpy(hdr + 26, &planes, 2);
  memcpy(hdr + 28, &bits, 2);
  uint8_t *dst = hdr + 54;
  for (int y = 0; y < ph; y++) {
    double t = (double)y / (ph - 1), scrim = 0;
    if (t < 0.22)
      scrim = 0.06 * (1.0 - t / 0.22);
    else if (t > 0.42) {
      double u = (t - 0.42) / 0.58;
      scrim = 0.88 * u * u * (1.45 - 0.45 * u);
    }
    double keep = 1.0 - scrim;
    int y0 = cy0 + y * ch / ph, y1 = cy0 + (y + 1) * ch / ph;
    if (y1 <= y0)
      y1 = y0 + 1;
    if (y1 > h)
      y1 = h;
    uint8_t *d = dst + (size_t)y * pw * 4;
    for (int x = 0; x < pw; x++) {
      int x0 = cx0 + x * cw / pw, x1 = cx0 + (x + 1) * cw / pw;
      if (x1 <= x0)
        x1 = x0 + 1;
      if (x1 > w)
        x1 = w;
      uint32_t sb = 0, sg = 0, sr = 0, cnt = 0;
      for (int yy = y0; yy < y1; yy++) {
        const uint8_t *s = px + (size_t)yy * pitch;
        for (int xx = x0; xx < x1; xx++, cnt++) {
          sb += s[xx * 4];
          sg += s[xx * 4 + 1];
          sr += s[xx * 4 + 2];
        }
      }
      d[x * 4] = (uint8_t)((double)sb / cnt * keep + 17.0 * scrim + 0.5);
      d[x * 4 + 1] = (uint8_t)((double)sg / cnt * keep + 13.0 * scrim + 0.5);
      d[x * 4 + 2] = (uint8_t)((double)sr / cnt * keep + 12.0 * scrim + 0.5);
      d[x * 4 + 3] = 255;
    }
  }
  CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  return out;
}

// ---- the region and its screen ----

static struct {
  BOOL prepared;
  int x, y, w, h;          // the region, in the screens' pixels (mac_platform.h's ps_screen_pixels)
  int mx, my, mw, mh;      // its screen's
  int session;             // the panel's number: ps_rec_end begins another (a worker of the last keeps nothing)
  BOOL inputShow;
} R;
static NSScreen *recScreen;  // (R.screen kept alive)
static NSMutableSet<NSNumber *> *excluded;  // the windows kept out of the recording (their window numbers)

static NSRect regionPoints(void) {
  return ps_screen_points(recScreen, NSMakeRect(R.x, R.y, R.w, R.h));
}

static void postRect(void) {
  NSString *s =
      [NSString stringWithFormat:@"{\"do\":\"rec-rect\",\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d}", R.x, R.y, R.w, R.h];
  mb_post("ps", s.UTF8String, strlen(s.UTF8String), NULL, 0);
}

// ---- the frame round the region ----

@interface PSRecFrameView : NSView
@property NSColor *color;
@property BOOL dashed, handles;
@end

@interface PSRecFrameWindow : NSPanel
@end
@implementation PSRecFrameWindow
- (BOOL)canBecomeKeyWindow {
  return NO;
}
- (BOOL)canBecomeMainWindow {
  return NO;
}
@end

static const CGFloat framePad = 10;  // the window reaches this far round the region (the glow, the edges' grip)
static PSRecFrameWindow *frameWin;
static PSRecFrameView *frameView;
static void recDrawRegion(void);

static void framePlace(void) {
  if (!frameWin)
    return;
  NSRect r = NSInsetRect(regionPoints(), -framePad, -framePad);
  [frameWin setFrame:r display:YES];
  frameView.needsDisplay = YES;
}

@implementation PSRecFrameView {
  int dragX, dragY;  // which edges a drag moves (-1 left/top, 1 right/bottom)
  NSPoint dragFrom;
  int fromX, fromY, fromW, fromH;
}
- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e {
  return YES;
}
// The border's rectangle in the view (just outside the region; kept on its screen where the region is its edge).
- (NSRect)borderRect {
  NSRect b = NSInsetRect(self.bounds, framePad - 2, framePad - 2);
  NSRect s = recScreen.frame;
  NSRect onScreen = [self.window convertRectFromScreen:NSInsetRect(s, 2, 2)];
  onScreen = [self convertRect:onScreen fromView:nil];
  return NSIntersectionRect(b, onScreen);
}
- (NSBezierPath *)roundRect:(NSRect)r {
  CGFloat rad = MIN(6, MIN(NSWidth(r), NSHeight(r)) * 0.5 * 0.35);
  return [NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad];
}
- (void)drawRect:(NSRect)dirty {
  NSRect r = [self borderRect];
  if (NSIsEmptyRect(r))
    return;
  CGContextRef c = NSGraphicsContext.currentContext.CGContext;
  NSColor *col = [self.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (self.handles) {
    // (an all but invisible band where the edges are gripped: a click on nothing at all would go through the window)
    NSBezierPath *grip = [self roundRect:r];
    grip.lineWidth = 16;
    [[NSColor colorWithWhite:0 alpha:0.01] setStroke];
    [grip stroke];
  }
  CGFloat halfW = self.handles ? 0.95 : 1.1;
  // the glow
  CGContextSaveGState(c);
  CGContextSetShadowWithColor(c, CGSizeZero, 6, [col colorWithAlphaComponent:0.55].CGColor);
  NSBezierPath *p = [self roundRect:r];
  p.lineWidth = halfW * 2;
  [[col colorWithAlphaComponent:0.28] setStroke];
  [p stroke];
  CGContextRestoreGState(c);
  // a dark casing that keeps it seen on white
  p.lineWidth = (halfW + 1.35) * 2;
  [[NSColor colorWithWhite:0 alpha:0.32] setStroke];
  [p stroke];
  // the border
  p.lineWidth = halfW * 2;
  if (self.dashed) {
    CGFloat dash[] = {7, 6};
    [p setLineDash:dash count:2 phase:0];
  }
  [[col colorWithAlphaComponent:0.9] setStroke];
  [p stroke];
  if (!self.handles)
    return;
  // the corners' brackets and the edges' middle grips, lighter
  NSColor *light = [NSColor colorWithSRGBRed:MIN(1, col.redComponent + 0.28)
                                       green:MIN(1, col.greenComponent + 0.28)
                                        blue:MIN(1, col.blueComponent + 0.28)
                                       alpha:1];
  CGFloat blen = MAX(MIN(MIN(NSWidth(r), NSHeight(r)) * 0.16, 16), 9);
  blen = MIN(blen, MIN(NSWidth(r), NSHeight(r)) * 0.45);
  CGFloat rad = MIN(6, MIN(NSWidth(r), NSHeight(r)) * 0.5 * 0.35);
  NSBezierPath *marks = [NSBezierPath bezierPath];
  CGFloat x0 = NSMinX(r), y0 = NSMinY(r), x1 = NSMaxX(r), y1 = NSMaxY(r);
  CGFloat xs[] = {x0, x1}, ys[] = {y0, y1};
  for (int i = 0; i < 2; i++)
    for (int j = 0; j < 2; j++) {
      CGFloat x = xs[i], y = ys[j], sx = i ? -1 : 1, sy = j ? -1 : 1;
      [marks moveToPoint:NSMakePoint(x + sx * blen, y)];
      [marks lineToPoint:NSMakePoint(x + sx * rad, y)];
      [marks curveToPoint:NSMakePoint(x, y + sy * rad) controlPoint1:NSMakePoint(x, y) controlPoint2:NSMakePoint(x, y)];
      [marks lineToPoint:NSMakePoint(x, y + sy * blen)];
    }
  if (R.w >= 54 * recScreen.backingScaleFactor / 1) {
    CGFloat mx = NSMidX(r);
    [marks moveToPoint:NSMakePoint(mx - 7, y0)];
    [marks lineToPoint:NSMakePoint(mx + 7, y0)];
    [marks moveToPoint:NSMakePoint(mx - 7, y1)];
    [marks lineToPoint:NSMakePoint(mx + 7, y1)];
  }
  if (R.h >= 54 * recScreen.backingScaleFactor / 1) {
    CGFloat my = NSMidY(r);
    [marks moveToPoint:NSMakePoint(x0, my - 7)];
    [marks lineToPoint:NSMakePoint(x0, my + 7)];
    [marks moveToPoint:NSMakePoint(x1, my - 7)];
    [marks lineToPoint:NSMakePoint(x1, my + 7)];
  }
  marks.lineCapStyle = NSLineCapStyleRound;
  marks.lineJoinStyle = NSLineJoinStyleRound;
  marks.lineWidth = 3.3 + 2.7;
  [[NSColor colorWithWhite:0 alpha:0.42] setStroke];
  [marks stroke];
  marks.lineWidth = 3.3;
  [light setStroke];
  [marks stroke];
}
// Which edges a point grips (0, 0: none).
- (BOOL)grip:(NSPoint)p x:(int *)hx y:(int *)hy {
  NSRect r = [self borderRect];
  CGFloat reach = 9, corner = 18;
  *hx = *hy = 0;
  if (!NSPointInRect(p, NSInsetRect(r, -reach, -reach)) || NSPointInRect(p, NSInsetRect(r, reach, reach)))
    return NO;
  if (fabs(p.x - NSMinX(r)) <= reach)
    *hx = -1;
  else if (fabs(p.x - NSMaxX(r)) <= reach)
    *hx = 1;
  if (fabs(p.y - NSMinY(r)) <= reach)
    *hy = -1;
  else if (fabs(p.y - NSMaxY(r)) <= reach)
    *hy = 1;
  if (*hx && !*hy)
    *hy = p.y <= NSMinY(r) + corner ? -1 : p.y >= NSMaxY(r) - corner ? 1 : 0;
  else if (*hy && !*hx)
    *hx = p.x <= NSMinX(r) + corner ? -1 : p.x >= NSMaxX(r) - corner ? 1 : 0;
  return *hx || *hy;
}
- (NSView *)hitTest:(NSPoint)p {
  if (!self.handles)
    return nil;
  int hx, hy;
  return [self grip:[self convertPoint:p fromView:self.superview] x:&hx y:&hy] ? self : nil;
}
static NSCursor *cursorFor(int hx, int hy) {
  if (@available(macOS 15.0, *)) {
    NSCursorFrameResizePosition pos = hx < 0   ? (hy < 0 ? NSCursorFrameResizePositionTopLeft
                                                         : hy > 0 ? NSCursorFrameResizePositionBottomLeft
                                                                  : NSCursorFrameResizePositionLeft)
                                      : hx > 0 ? (hy < 0 ? NSCursorFrameResizePositionTopRight
                                                         : hy > 0 ? NSCursorFrameResizePositionBottomRight
                                                                  : NSCursorFrameResizePositionRight)
                                               : (hy < 0 ? NSCursorFrameResizePositionTop
                                                         : NSCursorFrameResizePositionBottom);
    return [NSCursor frameResizeCursorFromPosition:pos inDirections:NSCursorFrameResizeDirectionsAll];
  }
  if (hx && !hy)
    return NSCursor.resizeLeftRightCursor;
  if (hy && !hx)
    return NSCursor.resizeUpDownCursor;
  return NSCursor.crosshairCursor;
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea *a in self.trackingAreas)
    [self removeTrackingArea:a];
  [self addTrackingArea:[[NSTrackingArea alloc]
                            initWithRect:self.bounds
                                 options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                         NSTrackingActiveAlways | NSTrackingInVisibleRect
                                   owner:self
                                userInfo:nil]];
}
- (void)mouseMoved:(NSEvent *)e {
  int hx, hy;
  if (self.handles && [self grip:[self convertPoint:e.locationInWindow fromView:nil] x:&hx y:&hy])
    [cursorFor(hx, hy) set];
  else
    [NSCursor.arrowCursor set];
}
- (void)mouseExited:(NSEvent *)e {
  if (!dragX && !dragY)
    [NSCursor.arrowCursor set];
}
- (void)mouseDown:(NSEvent *)e {
  int hx, hy;
  if (!self.handles || ![self grip:[self convertPoint:e.locationInWindow fromView:nil] x:&hx y:&hy])
    return;
  dragX = hx;
  dragY = hy;
  dragFrom = [self.window convertPointToScreen:e.locationInWindow];
  fromX = R.x, fromY = R.y, fromW = R.w, fromH = R.h;
  [cursorFor(hx, hy) set];
}
- (void)mouseDragged:(NSEvent *)e {
  if (!dragX && !dragY)
    return;
  CGFloat k = recScreen.backingScaleFactor;
  NSPoint p = [self.window convertPointToScreen:e.locationInWindow];
  int dx = (int)lround((p.x - dragFrom.x) * k), dy = (int)lround((dragFrom.y - p.y) * k);
  int minSz = (int)(64 * k / 2) * 2;
  int ml = R.mx, mt = R.my, mr = R.mx + R.mw, mb = R.my + R.mh;
  int x0 = fromX, y0 = fromY, x1 = fromX + fromW, y1 = fromY + fromH;
  if (dragX < 0)
    x0 = MAX(ml, MIN(x1 - minSz, x0 + dx));
  else if (dragX > 0)
    x1 = MIN(mr, MAX(x0 + minSz, x1 + dx));
  if (dragY < 0)
    y0 = MAX(mt, MIN(y1 - minSz, y0 + dy));
  else if (dragY > 0)
    y1 = MIN(mb, MAX(y0 + minSz, y1 + dy));
  int nw = MAX(minSz, (x1 - x0) & ~1), nh = MAX(minSz, (y1 - y0) & ~1);
  int nx = MAX(ml, dragX < 0 ? x1 - nw : x0), ny = MAX(mt, dragY < 0 ? y1 - nh : y0);
  if (nx + nw > mr)
    nw = (mr - nx) & ~1;
  if (ny + nh > mb)
    nh = (mb - ny) & ~1;
  if (nw >= minSz && nh >= minSz && (nx != R.x || ny != R.y || nw != R.w || nh != R.h)) {
    R.x = nx, R.y = ny, R.w = nw, R.h = nh;
    framePlace();
    postRect();
  }
}
- (void)mouseUp:(NSEvent *)e {
  if (!dragX && !dragY)
    return;
  dragX = dragY = 0;
  recDrawRegion();
  postRect();
}
@end

static void frameShow(NSColor *color, BOOL dashed, BOOL handles) {
  if (!frameWin) {
    frameWin = [[PSRecFrameWindow alloc] initWithContentRect:NSMakeRect(0, 0, 16, 16)
                                                   styleMask:NSWindowStyleMaskBorderless |
                                                             NSWindowStyleMaskNonactivatingPanel
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    frameWin.opaque = NO;
    frameWin.backgroundColor = NSColor.clearColor;
    frameWin.hasShadow = NO;
    frameWin.releasedWhenClosed = NO;
    frameWin.level = NSFloatingWindowLevel;
    frameWin.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                  NSWindowCollectionBehaviorFullScreenAuxiliary |
                                  NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
    if (!getenv("PINSHOT_REC_SHOW"))
      frameWin.sharingType = NSWindowSharingNone;
    frameView = [[PSRecFrameView alloc] initWithFrame:NSMakeRect(0, 0, 16, 16)];
    frameWin.contentView = frameView;
    [excluded addObject:@(frameWin.windowNumber)];
  }
  frameView.color = color;
  frameView.dashed = dashed;
  frameView.handles = handles;
  frameWin.ignoresMouseEvents = !handles;
  framePlace();
  [frameWin orderFrontRegardless];
}

static void frameHide(void) {
  if (!frameWin)
    return;
  [excluded removeObject:@(frameWin.windowNumber)];
  [frameWin orderOut:nil];
  [frameWin close];
  frameWin = nil;
  frameView = nil;
}

static NSColor *rgb(int c) {
  return [NSColor colorWithSRGBRed:((c >> 16) & 255) / 255.0 green:((c >> 8) & 255) / 255.0 blue:(c & 255) / 255.0
                             alpha:1];
}

// ---- clicks and keys shown over the region ----

typedef struct {
  NSPoint at;  // in the region's view
  int rgb;
  double start;
} Ripple;

@interface PSRecDrawView : NSView
@end

static NSWindow *drawWin;
static PSRecDrawView *drawView;
static id mouseMonitor, keyMonitor;
static NSTimer *drawTimer;
static BOOL drawRecording;
static Ripple ripples[8];
static int rippleCount;
static NSArray<NSString *> *caps;
static double capsStart;
static const double rippleMs = 400, keyHoldMs = 1100, keyFadeMs = 350;

static BOOL drawBusy(double now) {
  return rippleCount > 0 || (caps && now < capsStart + keyHoldMs + keyFadeMs);
}

@implementation PSRecDrawView
- (BOOL)isFlipped {
  return YES;
}
- (NSView *)hitTest:(NSPoint)p {
  return nil;
}
- (void)drawRect:(NSRect)dirty {
  double now = ps_now_ms();
  for (int i = 0; i < rippleCount; i++) {
    double t = (now - ripples[i].start) / rippleMs;
    if (t < 0 || t >= 1)
      continue;
    double ease = 1 - (1 - t) * (1 - t), rad = 8 + 24 * ease;
    NSRect box = NSMakeRect(ripples[i].at.x - rad, ripples[i].at.y - rad, rad * 2, rad * 2);
    NSBezierPath *c = [NSBezierPath bezierPathWithOvalInRect:box];
    [[rgb(ripples[i].rgb) colorWithAlphaComponent:(1 - t) * 60 / 255.0] setFill];
    [c fill];
    c.lineWidth = 2.5;
    [[rgb(ripples[i].rgb) colorWithAlphaComponent:(1 - t) * 220 / 255.0] setStroke];
    [c stroke];
  }
  if (!caps.count)
    return;
  double age = now - capsStart;
  double alpha = age > keyHoldMs ? 1 - (age - keyHoldMs) / keyFadeMs : 1;
  if (alpha <= 0.01)
    return;
  CGFloat ch = NSHeight(self.bounds) < 320 / 2.0 * 2 ? 28 : 34, gap = 6, total = 0;
  NSFont *font = [NSFont systemFontOfSize:ch * 0.48 weight:NSFontWeightBold];
  NSMutableParagraphStyle *mid = [NSMutableParagraphStyle new];
  mid.alignment = NSTextAlignmentCenter;
  NSDictionary *look = @{
    NSFontAttributeName : font,
    NSForegroundColorAttributeName : [NSColor colorWithWhite:1 alpha:245 / 255.0 * alpha],
    NSParagraphStyleAttributeName : mid
  };
  NSMutableArray<NSNumber *> *ws = [NSMutableArray array];
  for (NSString *c in caps) {
    CGFloat w = MAX(ch, [c sizeWithAttributes:look].width + 18);
    [ws addObject:@(w)];
    total += w;
  }
  total += gap * (caps.count - 1);
  CGFloat h = NSHeight(self.bounds), x = (NSWidth(self.bounds) - total) / 2;
  CGFloat y = MAX(8, h - ch - MIN(28, h * 0.08));
  for (NSUInteger i = 0; i < caps.count; i++) {
    CGFloat w = ws[i].doubleValue;
    NSBezierPath *shade = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y + 2.5, w, ch) xRadius:8 yRadius:8];
    [[NSColor colorWithWhite:0 alpha:95 / 255.0 * alpha] setFill];
    [shade fill];
    NSBezierPath *cap = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y, w, ch) xRadius:8 yRadius:8];
    [[NSColor colorWithSRGBRed:24 / 255.0 green:26 / 255.0 blue:31 / 255.0 alpha:230 / 255.0 * alpha] setFill];
    [cap fill];
    cap.lineWidth = 1.2;
    [[NSColor colorWithWhite:1 alpha:56 / 255.0 * alpha] setStroke];
    [cap stroke];
    CGFloat th = font.ascender - font.descender;
    [caps[i] drawInRect:NSMakeRect(x, y + (ch - th) / 2, w, th) withAttributes:look];
    x += w + gap;
  }
}
@end

static void drawTick(void) {
  double now = ps_now_ms();
  int n = 0;
  for (int i = 0; i < rippleCount; i++)
    if (now < ripples[i].start + rippleMs)
      ripples[n++] = ripples[i];
  rippleCount = n;
  if (caps && now >= capsStart + keyHoldMs + keyFadeMs)
    caps = nil;
  drawView.needsDisplay = YES;
  if (!drawBusy(now)) {
    [drawTimer invalidate];
    drawTimer = nil;
  }
}

static void drawWake(void) {
  drawView.needsDisplay = YES;
  if (!drawTimer)
    drawTimer = [NSTimer scheduledTimerWithTimeInterval:1 / 60.0
                                                repeats:YES
                                                  block:^(NSTimer *t) { drawTick(); }];
}

static NSString *keyLabel(NSEvent *e) {
  switch (e.keyCode) {
  case 36:
  case 76:
    return @"↩";
  case 53:
    return @"Esc";
  case 49:
    return @"Space";
  case 48:
    return @"⇥";
  case 51:
    return @"⌫";
  case 117:
    return @"⌦";
  case 115:
    return @"Home";
  case 119:
    return @"End";
  case 116:
    return @"PgUp";
  case 121:
    return @"PgDn";
  case 123:
    return @"←";
  case 124:
    return @"→";
  case 125:
    return @"↓";
  case 126:
    return @"↑";
  }
  static const int fkeys[] = {122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111};
  for (int i = 0; i < 12; i++)
    if (e.keyCode == fkeys[i])
      return [NSString stringWithFormat:@"F%d", i + 1];
  NSString *s = e.charactersIgnoringModifiers.uppercaseString;
  if (!s.length || [s characterAtIndex:0] < 0x20 || ([s characterAtIndex:0] >= 0xF700 && [s characterAtIndex:0] <= 0xF8FF))
    return nil;
  return s;
}

static void drawSync(void) {
  BOOL want = R.prepared && R.inputShow && drawRecording;
  if (!want) {
    if (mouseMonitor)
      [NSEvent removeMonitor:mouseMonitor];
    if (keyMonitor)
      [NSEvent removeMonitor:keyMonitor];
    mouseMonitor = keyMonitor = nil;
    [drawTimer invalidate];
    drawTimer = nil;
    rippleCount = 0;
    caps = nil;
    [drawWin orderOut:nil];
    [drawWin close];
    drawWin = nil;
    drawView = nil;
    return;
  }
  if (!drawWin) {
    drawWin = [[NSWindow alloc] initWithContentRect:regionPoints()
                                          styleMask:NSWindowStyleMaskBorderless
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    drawWin.opaque = NO;
    drawWin.backgroundColor = NSColor.clearColor;
    drawWin.hasShadow = NO;
    drawWin.releasedWhenClosed = NO;
    drawWin.ignoresMouseEvents = YES;
    drawWin.level = NSStatusWindowLevel;
    drawWin.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                 NSWindowCollectionBehaviorFullScreenAuxiliary |
                                 NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
    drawView = [[PSRecDrawView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)];
    drawWin.contentView = drawView;
  }
  [drawWin setFrame:regionPoints() display:NO];
  [drawWin orderFrontRegardless];
  if (!mouseMonitor)
    mouseMonitor = [NSEvent
        addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
                                              NSEventMaskOtherMouseDown
                                      handler:^(NSEvent *e) {
                                        NSPoint p = e.window ? [e.window convertPointToScreen:e.locationInWindow] : e.locationInWindow;
                                        NSRect r = drawWin.frame;
                                        if (!NSPointInRect(p, r))
                                          return;
                                        if (rippleCount == 8) {
                                          memmove(ripples, ripples + 1, sizeof(Ripple) * 7);
                                          rippleCount--;
                                        }
                                        ripples[rippleCount++] = (Ripple){
                                            NSMakePoint(p.x - NSMinX(r), NSMaxY(r) - p.y),
                                            e.type == NSEventTypeRightMouseDown   ? 0xF5A524
                                            : e.type == NSEventTypeOtherMouseDown ? 0x4CC38A
                                                                                  : 0x2F9BFF,
                                            ps_now_ms()};
                                        drawWake();
                                      }];
  // (keys only where the person let PinShot watch them: never asked here, the recording goes on without them)
  if (!keyMonitor && AXIsProcessTrusted())
    keyMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                        handler:^(NSEvent *e) {
                                                          NSString *k = keyLabel(e);
                                                          if (!k)
                                                            return;
                                                          NSEventModifierFlags m = e.modifierFlags;
                                                          NSMutableArray *c = [NSMutableArray array];
                                                          if (m & NSEventModifierFlagControl)
                                                            [c addObject:@"⌃"];
                                                          if (m & NSEventModifierFlagOption)
                                                            [c addObject:@"⌥"];
                                                          if (m & NSEventModifierFlagShift)
                                                            [c addObject:@"⇧"];
                                                          if (m & NSEventModifierFlagCommand)
                                                            [c addObject:@"⌘"];
                                                          [c addObject:k];
                                                          caps = c;
                                                          capsStart = ps_now_ms();
                                                          drawWake();
                                                        }];
}

static void recDrawRegion(void) {
  if (drawWin)
    [drawWin setFrame:regionPoints() display:NO];
}

void ps_rec_input_show(int32_t on) {
  R.inputShow = on != 0;
  drawSync();
}

// ---- the recording ----

@interface PSRecorder : NSObject <SCStreamOutput, SCStreamDelegate>
@end

static PSRecorder *recorder;     // the recording running (main thread's)
static atomic_int recRunning;    // a recording's worker is there (till its file is written or let go)
static atomic_int recPaused;

// The recording kept to export (main thread's).
static NSString *masterPath, *masterCodec;
static uint64_t masterBytes;
static int64_t masterMs;
static int masterW, masterH, masterFps, masterAudio;
static NSData *masterPreview;

static NSString *tempPath(void) {
  return [NSTemporaryDirectory()
      stringByAppendingPathComponent:[NSString stringWithFormat:@"PinShot_rec_%d_%llu.mp4",
                                                                NSProcessInfo.processInfo.processIdentifier,
                                                                (unsigned long long)(ps_now_ms() * 1000)]];
}

static double hostSeconds(void) { return CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())); }

@implementation PSRecorder {
 @public
  int session, fps, w, h;
  BOOL cursor, wantAudio;
  SCStream *stream;
  dispatch_queue_t q;  // the stream's frames and sound, and everything of the writer, on it alone
  AVAssetWriter *writer;
  AVAssetWriterInput *vin, *ain;
  AVAssetWriterInputPixelBufferAdaptor *adaptor;
  NSString *path, *codec;
  BOOL hasAudio;
  // (q's)
  BOOL started, stopping, failed;
  CMTime origin;       // the host time the recording's time 0 is
  double pausedTotal;  // seconds paused, taken off every time after
  double pauseBegan;
  BOOL wasPaused;
  CMTime lastPts;
  CVPixelBufferRef lastFrame;
  int frames;
  // (main's)
  double startedAt;     // host seconds the recording was asked to start
  dispatch_source_t ticker;
}

- (int64_t)elapsedMs {
  double now = hostSeconds();
  double paused = pausedTotal + (wasPaused ? now - pauseBegan : 0);
  double t = started ? now - CMTimeGetSeconds(origin) - paused : 0;
  return (int64_t)(MAX(0, t) * 1000);
}

- (BOOL)makeWriter {
  NSError *err = nil;
  writer = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:path] fileType:AVFileTypeMPEG4 error:&err];
  if (!writer)
    return NO;
  writer.shouldOptimizeForNetworkUse = YES;
  for (int tryCodec = 0; tryCodec < 2 && !vin; tryCodec++) {
    NSDictionary *s = @{
      AVVideoCodecKey : tryCodec == 0 ? AVVideoCodecTypeHEVC : AVVideoCodecTypeH264,
      AVVideoWidthKey : @(w),
      AVVideoHeightKey : @(h),
      AVVideoColorPropertiesKey : @{
        AVVideoColorPrimariesKey : AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey : AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey : AVVideoYCbCrMatrix_ITU_R_709_2
      },
      AVVideoCompressionPropertiesKey : @{
        AVVideoAverageBitRateKey : @(targetBps(tryCodec, 0, w, h, fps)),
        AVVideoExpectedSourceFrameRateKey : @(fps),
        AVVideoMaxKeyFrameIntervalKey : @(fps * 2),
        AVVideoAllowFrameReorderingKey : @NO,
        AVVideoProfileLevelKey : tryCodec == 0 ? (id)kVTProfileLevel_HEVC_Main_AutoLevel
                                               : AVVideoProfileLevelH264HighAutoLevel,
      }
    };
    if (![writer canApplyOutputSettings:s forMediaType:AVMediaTypeVideo])
      continue;
    vin = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:s];
    codec = tryCodec == 0 ? @"HEVC (HW)" : @"H.264 (HW)";
  }
  if (!vin || ![writer canAddInput:vin])
    return NO;
  vin.expectsMediaDataInRealTime = YES;
  [writer addInput:vin];
  adaptor = [AVAssetWriterInputPixelBufferAdaptor
      assetWriterInputPixelBufferAdaptorWithAssetWriterInput:vin
                                 sourcePixelBufferAttributes:nil];
  if (wantAudio) {
    NSDictionary *as = @{
      AVFormatIDKey : @(kAudioFormatMPEG4AAC),
      AVSampleRateKey : @48000,
      AVNumberOfChannelsKey : @2,
      AVEncoderBitRateKey : @128000
    };
    ain = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:as];
    ain.expectsMediaDataInRealTime = YES;
    if ([writer canAddInput:ain]) {
      [writer addInput:ain];
      hasAudio = YES;
    } else
      ain = nil;
  }
  return [writer startWriting];
}

- (void)tick {
  if (stopping)
    return;
  recPost(atomic_load(&recPaused) ? @"paused" : @"recording", [self elapsedMs], frames, 0, 0, 0, hasAudio, codec,
          nil, nil);
}

- (void)begin:(SCContentFilter *)filter {
  SCStreamConfiguration *c = [SCStreamConfiguration new];
  CGRect display = CGDisplayBounds(ps_display_id(recScreen));
  CGFloat k = recScreen.backingScaleFactor;
  c.sourceRect = CGRectMake((R.x - display.origin.x) / k, (R.y - display.origin.y) / k, w / k, h / k);
  c.width = w;
  c.height = h;
  c.scalesToFit = NO;
  c.minimumFrameInterval = CMTimeMake(1, fps);
  c.queueDepth = 6;
  c.pixelFormat = kCVPixelFormatType_32BGRA;
  c.colorSpaceName = kCGColorSpaceSRGB;
  c.showsCursor = cursor;
  c.capturesAudio = wantAudio;
  c.sampleRate = 48000;
  c.channelCount = 2;
  c.excludesCurrentProcessAudio = YES;
  stream = [[SCStream alloc] initWithFilter:filter configuration:c delegate:self];
  NSError *err = nil;
  if (![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:q error:&err] ||
      (wantAudio && ![stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:q error:&err])) {
    [self fail:@"录屏失败"];
    return;
  }
  [stream startCaptureWithCompletionHandler:^(NSError *e) {
    if (e) {
      NSLog(@"PinShot rec: %@", e);
      [self fail:@"录屏失败"];
    }
  }];
}

// The recording given up: told once, its file let go.
- (void)fail:(NSString *)why {
  dispatch_async(q, ^{
    if (self->failed || self->stopping)
      return;
    self->failed = YES;
    self->stopping = YES;
    [self->stream stopCaptureWithCompletionHandler:nil];
    [self->writer cancelWriting];
    [NSFileManager.defaultManager removeItemAtPath:self->path error:nil];
    if (self->lastFrame)
      CVPixelBufferRelease(self->lastFrame);
    self->lastFrame = NULL;
    atomic_store(&recRunning, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
      [self stopTicker];
      if (recorder == self)
        recorder = nil;
    });
    recPost(@"error", [self elapsedMs], self->frames, 0, 0, 0, 0, self->codec, nil, why);
  });
}

- (void)stream:(SCStream *)s didStopWithError:(NSError *)error {
  NSLog(@"PinShot rec stopped: %@", error);
  [self fail:@"录屏失败"];
}

- (void)stopTicker {
  if (ticker)
    dispatch_source_cancel(ticker);
  ticker = nil;
}

// (q's) The pause asked for, taken as a frame or a sound comes: the time paused taken off all after it.
- (BOOL)pausedNow {
  BOOL p = atomic_load(&recPaused) != 0;
  if (p && !wasPaused) {
    wasPaused = YES;
    pauseBegan = hostSeconds();
  } else if (!p && wasPaused) {
    wasPaused = NO;
    pausedTotal += hostSeconds() - pauseBegan;
  }
  return p;
}

- (CMTime)recTime:(CMTime)pts {
  return CMTimeSubtract(CMTimeSubtract(pts, origin), CMTimeMakeWithSeconds(pausedTotal, 1000000));
}

- (void)stream:(SCStream *)s didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
  if (stopping || !CMSampleBufferIsValid(sb))
    return;
  if (type == SCStreamOutputTypeScreen) {
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, NO);
    if (!att || CFArrayGetCount(att) == 0)
      return;
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(att, 0);
    if ([info[SCStreamFrameInfoStatus] integerValue] != SCFrameStatusComplete)
      return;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb)
      return;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    if (!started) {
      started = YES;
      origin = pts;
      [writer startSessionAtSourceTime:kCMTimeZero];
    }
    if ([self pausedNow])
      return;
    CMTime t = [self recTime:pts];
    if (frames > 0 && CMTimeCompare(t, lastPts) <= 0)
      return;
    if (lastFrame)
      CVPixelBufferRelease(lastFrame);
    lastFrame = CVPixelBufferRetain(pb);
    if (vin.readyForMoreMediaData && [adaptor appendPixelBuffer:pb withPresentationTime:t]) {
      lastPts = t;
      frames++;
    } else if (writer.status == AVAssetWriterStatusFailed) {
      NSLog(@"PinShot rec writer: %@", writer.error);
      [self fail:@"无法初始化视频编码器"];
    }
  } else if (type == SCStreamOutputTypeAudio && ain) {
    if (!started || [self pausedNow])
      return;
    CMItemCount n = 0;
    CMSampleBufferGetSampleTimingInfoArray(sb, 0, NULL, &n);
    if (n <= 0)
      return;
    CMSampleTimingInfo *ti = calloc(n, sizeof *ti);
    CMSampleBufferGetSampleTimingInfoArray(sb, n, ti, &n);
    for (CMItemCount i = 0; i < n; i++) {
      ti[i].presentationTimeStamp = [self recTime:ti[i].presentationTimeStamp];
      ti[i].decodeTimeStamp = kCMTimeInvalid;
    }
    CMSampleBufferRef out = NULL;
    CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sb, n, ti, &out);
    free(ti);
    if (out) {
      if (CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(out)) >= 0 && ain.readyForMoreMediaData)
        [ain appendSampleBuffer:out];
      CFRelease(out);
    }
  }
}

// The recording finished (or called off): its last frame held to the end, its file written, told.
- (void)finish:(BOOL)cancel {
  [self stopTicker];
  dispatch_async(q, ^{
    if (self->stopping)
      return;
    self->stopping = YES;
    int64_t ms = [self elapsedMs];
    if (!cancel)
      recPost(@"saving", ms, self->frames, 0, 0, 0, self->hasAudio, self->codec, nil, nil);
    if (!self->stream) {
      [self written:cancel ms:ms];
      return;
    }
    [self->stream stopCaptureWithCompletionHandler:^(NSError *e) {
      dispatch_async(self->q, ^{ [self written:cancel ms:ms]; });
    }];
  });
}

- (void)written:(BOOL)cancel ms:(int64_t)ms {
  if (cancel || self->frames == 0) {
    [writer cancelWriting];
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    if (lastFrame)
      CVPixelBufferRelease(lastFrame);
    lastFrame = NULL;
    atomic_store(&recRunning, 0);
    if (cancel)
      recPost(@"cancelled", ms, frames, 0, 0, 0, 0, codec, nil, nil);
    else
      recPost(@"error", ms, frames, 0, 0, 0, 0, codec, nil, @"保存录屏文件失败");
    dispatch_async(dispatch_get_main_queue(), ^{
      if (recorder == self)
        recorder = nil;
    });
    return;
  }
  // (the last frame held till the recording's end: a still screen gave no frames after it)
  CMTime end = CMTimeMakeWithSeconds(ms / 1000.0, 600);
  if (lastFrame && CMTimeCompare(end, lastPts) > 0 && vin.readyForMoreMediaData)
    [adaptor appendPixelBuffer:lastFrame withPresentationTime:end];
  [vin markAsFinished];
  [ain markAsFinished];
  [writer endSessionAtSourceTime:CMTimeCompare(end, lastPts) > 0 ? end : lastPts];
  NSData *preview = previewBmp(lastFrame);
  if (lastFrame)
    CVPixelBufferRelease(lastFrame);
  lastFrame = NULL;
  [writer finishWritingWithCompletionHandler:^{
    BOOL ok = self->writer.status == AVAssetWriterStatusCompleted;
    uint64_t bytes = ok ? fileSize(self->path) : 0;
    dispatch_async(dispatch_get_main_queue(), ^{
      atomic_store(&recRunning, 0);
      if (recorder == self)
        recorder = nil;
      if (!ok || bytes == 0) {
        [NSFileManager.defaultManager removeItemAtPath:self->path error:nil];
        recPost(@"error", ms, self->frames, 0, 0, 0, 0, self->codec, nil, @"保存录屏文件失败");
        return;
      }
      if (self->session != R.session) {
        // (the panel ended meanwhile: nothing kept of it)
        [NSFileManager.defaultManager removeItemAtPath:self->path error:nil];
        return;
      }
      if (masterPath && ![masterPath isEqual:self->path])
        [NSFileManager.defaultManager removeItemAtPath:masterPath error:nil];
      masterPath = self->path;
      masterBytes = bytes;
      masterMs = ms;
      masterW = self->w;
      masterH = self->h;
      masterFps = self->fps;
      masterAudio = self->hasAudio;
      masterCodec = self->codec;
      masterPreview = preview;
      recPost(@"recorded", ms, self->frames, bytes, bytes, 100, self->hasAudio, self->codec, self->path, nil);
    });
  }];
}
@end

int32_t ps_rec_prepare(int32_t x, int32_t y, int32_t w, int32_t h) {
  static BOOL swept;
  if (atomic_load(&recRunning) || recorder)
    return 0;
  if (!excluded)
    excluded = [NSMutableSet set];
  if (!swept) {
    swept = YES;
    // (the recordings of runs no longer here deleted, off the main thread; the one kept for export deleted as it quits)
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      NSString *dir = NSTemporaryDirectory();
      for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        if (![f hasPrefix:@"PinShot_rec_"] || ![f hasSuffix:@".mp4"])
          continue;
        pid_t pid = (pid_t)[[f substringFromIndex:12] intValue];
        if (pid > 0 && (kill(pid, 0) == 0 || errno == EPERM))
          continue;
        [NSFileManager.defaultManager removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
      }
    });
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillTerminateNotification
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification *n) {
                                                  if (masterPath)
                                                    [NSFileManager.defaultManager removeItemAtPath:masterPath
                                                                                             error:nil];
                                                }];
  }
  frameHide();
  if (w < 16 || h < 16)
    return 0;
  NSScreen *screen = nil;
  NSRect sp = NSZeroRect;
  for (NSScreen *s in NSScreen.screens) {
    NSRect p = ps_screen_pixels(s, s.frame);
    if (NSPointInRect(NSMakePoint(x + w / 2, y + h / 2), p)) {
      screen = s;
      sp = p;
      break;
    }
  }
  if (!screen) {
    screen = ps_capture_screen() ?: ps_mouse_screen();
    sp = ps_screen_pixels(screen, screen.frame);
  }
  int mx = (int)NSMinX(sp), my = (int)NSMinY(sp), mw = (int)NSWidth(sp), mh = (int)NSHeight(sp);
  if (x < mx)
    w -= mx - x, x = mx;
  if (y < my)
    h -= my - y, y = my;
  if (x + w > mx + mw)
    w = mx + mw - x;
  if (y + h > my + mh)
    h = my + mh - y;
  w &= ~1;
  h &= ~1;
  if (w < 16 || h < 16)
    return 0;
  recScreen = screen;
  R.prepared = YES;
  R.x = x, R.y = y, R.w = w, R.h = h;
  R.mx = mx, R.my = my, R.mw = mw, R.mh = mh;
  frameShow(rgb(0x2F9BFF), NO, YES);
  return 1;
}

moonbit_bytes_t ps_rec_rect(void) {
  if (!R.prepared)
    return moonbit_make_bytes(0, 0);
  return ps_string([NSString stringWithFormat:@"%d,%d,%d,%d", R.x, R.y, R.w, R.h]);
}

int32_t ps_rec_start(int32_t fps, int32_t cursor, int32_t audio) {
  if (!R.prepared || recorder || atomic_load(&recRunning))
    return 0;
  if (!CGPreflightScreenCaptureAccess())
    return 0;
  PSRecorder *r = [PSRecorder new];
  r->session = R.session;
  r->fps = fps < 10 ? 10 : fps > 120 ? 120 : fps;
  r->cursor = cursor != 0;
  r->wantAudio = audio != 0;
  r->w = R.w;
  r->h = R.h;
  r->path = tempPath();
  r->q = dispatch_queue_create("pinshot.rec", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                                   QOS_CLASS_USER_INTERACTIVE, 0));
  if (![r makeWriter]) {
    [NSFileManager.defaultManager removeItemAtPath:r->path error:nil];
    return 0;
  }
  atomic_store(&recPaused, 0);
  atomic_store(&recRunning, 1);
  recorder = r;
  r->startedAt = hostSeconds();
  CGDirectDisplayID displayID = ps_display_id(recScreen);
  NSSet<NSNumber *> *keepOut = [excluded copy];
  [SCShareableContent
      getShareableContentExcludingDesktopWindows:NO
                             onScreenWindowsOnly:YES
                               completionHandler:^(SCShareableContent *content, NSError *error) {
                                 SCDisplay *display = nil;
                                 for (SCDisplay *d in content.displays)
                                   if (d.displayID == displayID)
                                     display = d;
                                 if (!display) {
                                   [r fail:@"录屏失败"];
                                   return;
                                 }
                                 NSMutableArray<SCWindow *> *out = [NSMutableArray array];
                                 for (SCWindow *win in content.windows)
                                   if ([keepOut containsObject:@(win.windowID)])
                                     [out addObject:win];
                                 SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                                                                excludingWindows:out];
                                 dispatch_async(r->q, ^{
                                   if (!r->stopping)
                                     [r begin:filter];
                                 });
                               }];
  // (the time told as it goes, as Windows does: every tenth of a second)
  r->ticker = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, r->q);
  dispatch_source_set_timer(r->ticker, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC / 10, NSEC_PER_MSEC * 10);
  __weak PSRecorder *weak = r;
  dispatch_source_set_event_handler(r->ticker, ^{ [weak tick]; });
  dispatch_resume(r->ticker);
  frameShow(rgb(0xEF4444), NO, NO);
  drawRecording = YES;
  drawSync();
  return 1;
}

void ps_rec_pause(int32_t on) {
  if (!recorder)
    return;
  atomic_store(&recPaused, on ? 1 : 0);
  drawRecording = !on;
  drawSync();
  frameShow(on ? rgb(0xF5A524) : rgb(0xEF4444), on != 0, NO);
  PSRecorder *r = recorder;
  dispatch_async(r->q, ^{
    [r pausedNow];
    [r tick];
  });
}

void ps_rec_stop(int32_t cancel) {
  frameHide();
  drawRecording = NO;
  drawSync();
  if (recorder)
    [recorder finish:cancel != 0];
}

// ---- export ----

static atomic_int expGen;       // each export's number: one called off (or the panel ended) takes the next
static atomic_int expRunning;

static BOOL expLive(int gen) { return atomic_load(&expGen) == gen; }

// An MP4 encoded again from the recording (fmt 0 HEVC, 1 H.264) at `qual` and the size asked.
static void exportMp4(int gen, NSString *src, NSString *dst, int fmt, int qual, int ow, int oh, int fps,
                      int64_t totalMs, uint64_t orig) {
  NSString *cname = fmt == 0 ? @"HEVC (HW)" : @"H.264 (HW)";
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:src] options:nil];
  NSError *err = nil;
  AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
  AVAssetTrack *vt = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  AVAssetTrack *at = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
  if (!reader || !vt) {
    recPost(@"export-error", totalMs, 0, 0, orig, 0, 0, @"", dst, @"读取源视频失败");
    return;
  }
  AVAssetReaderTrackOutput *vout = [AVAssetReaderTrackOutput
      assetReaderTrackOutputWithTrack:vt
                       outputSettings:@{
                         (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                         (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
                       }];
  vout.alwaysCopiesSampleData = NO;
  [reader addOutput:vout];
  AVAssetReaderTrackOutput *aout = nil;
  if (at) {
    aout = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:at outputSettings:nil];
    if ([reader canAddOutput:aout])
      [reader addOutput:aout];
    else
      aout = nil;
  }
  [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
  [NSFileManager.defaultManager createDirectoryAtPath:dst.stringByDeletingLastPathComponent
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:dst]
                                                   fileType:AVFileTypeMPEG4
                                                      error:&err];
  NSDictionary *vs = @{
    AVVideoCodecKey : fmt == 0 ? AVVideoCodecTypeHEVC : AVVideoCodecTypeH264,
    AVVideoWidthKey : @(ow),
    AVVideoHeightKey : @(oh),
    AVVideoColorPropertiesKey : @{
      AVVideoColorPrimariesKey : AVVideoColorPrimaries_ITU_R_709_2,
      AVVideoTransferFunctionKey : AVVideoTransferFunction_ITU_R_709_2,
      AVVideoYCbCrMatrixKey : AVVideoYCbCrMatrix_ITU_R_709_2
    },
    AVVideoCompressionPropertiesKey : @{
      AVVideoAverageBitRateKey : @(targetBps(fmt == 0 ? 0 : 1, qual, ow, oh, fps)),
      AVVideoExpectedSourceFrameRateKey : @(fps),
      AVVideoMaxKeyFrameIntervalKey : @(fps * 2),
      AVVideoProfileLevelKey : fmt == 0 ? (id)kVTProfileLevel_HEVC_Main_AutoLevel
                                        : AVVideoProfileLevelH264HighAutoLevel,
    }
  };
  if (!writer || ![writer canApplyOutputSettings:vs forMediaType:AVMediaTypeVideo]) {
    recPost(@"export-error", totalMs, 0, 0, orig, 0, 0, @"", dst, @"无法启动压缩编码");
    return;
  }
  writer.shouldOptimizeForNetworkUse = YES;
  AVAssetWriterInput *vin = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:vs];
  [writer addInput:vin];
  AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
      assetWriterInputPixelBufferAdaptorWithAssetWriterInput:vin
                                 sourcePixelBufferAttributes:@{
                                   (id)kCVPixelBufferPixelFormatTypeKey :
                                       @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                                   (id)kCVPixelBufferWidthKey : @(ow),
                                   (id)kCVPixelBufferHeightKey : @(oh),
                                   (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
                                 }];
  AVAssetWriterInput *ain = nil;
  if (aout) {
    CMFormatDescriptionRef hint = (__bridge CMFormatDescriptionRef)at.formatDescriptions.firstObject;
    ain = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:nil sourceFormatHint:hint];
    if ([writer canAddInput:ain])
      [writer addInput:ain];
    else
      ain = nil;
  }
  if (![reader startReading] || ![writer startWriting]) {
    recPost(@"export-error", totalMs, 0, 0, orig, 0, 0, @"", dst, @"初始化转码失败");
    return;
  }
  [writer startSessionAtSourceTime:kCMTimeZero];
  BOOL resize = ow != masterW || oh != masterH;
  VTPixelTransferSessionRef xfer = NULL;
  if (resize)
    VTPixelTransferSessionCreate(kCFAllocatorDefault, &xfer);
  double total = MAX(0.001, totalMs / 1000.0);
  __block int lastPct = -1;
  __block BOOL bad = NO;
  dispatch_group_t g = dispatch_group_create();
  dispatch_queue_t vq = dispatch_queue_create("pinshot.export.v", DISPATCH_QUEUE_SERIAL);
  dispatch_queue_t aq = dispatch_queue_create("pinshot.export.a", DISPATCH_QUEUE_SERIAL);
  dispatch_group_enter(g);
  [vin requestMediaDataWhenReadyOnQueue:vq
                             usingBlock:^{
                               while (vin.readyForMoreMediaData) {
                                 if (!expLive(gen) || bad) {
                                   [vin markAsFinished];
                                   dispatch_group_leave(g);
                                   return;
                                 }
                                 CMSampleBufferRef sb = [vout copyNextSampleBuffer];
                                 if (!sb) {
                                   [vin markAsFinished];
                                   dispatch_group_leave(g);
                                   return;
                                 }
                                 CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
                                 CMTime t = CMSampleBufferGetPresentationTimeStamp(sb);
                                 BOOL ok = YES;
                                 if (pb && resize) {
                                   CVPixelBufferRef outPb = NULL;
                                   if (adaptor.pixelBufferPool)
                                     CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &outPb);
                                   if (outPb && xfer && VTPixelTransferSessionTransferImage(xfer, pb, outPb) == noErr)
                                     ok = [adaptor appendPixelBuffer:outPb withPresentationTime:t];
                                   else
                                     ok = NO;
                                   if (outPb)
                                     CVPixelBufferRelease(outPb);
                                 } else if (pb)
                                   ok = [adaptor appendPixelBuffer:pb withPresentationTime:t];
                                 CFRelease(sb);
                                 if (!ok) {
                                   bad = YES;
                                   continue;
                                 }
                                 int pct = (int)MIN(99, CMTimeGetSeconds(t) / total * 100);
                                 if (pct != lastPct) {
                                   lastPct = pct;
                                   recPost(@"exporting", totalMs, 0, 0, orig, pct, ain != nil, cname, dst, nil);
                                 }
                               }
                             }];
  if (ain) {
    dispatch_group_enter(g);
    [ain requestMediaDataWhenReadyOnQueue:aq
                               usingBlock:^{
                                 while (ain.readyForMoreMediaData) {
                                   CMSampleBufferRef sb = expLive(gen) && !bad ? [aout copyNextSampleBuffer] : NULL;
                                   if (!sb) {
                                     [ain markAsFinished];
                                     dispatch_group_leave(g);
                                     return;
                                   }
                                   if (![ain appendSampleBuffer:sb])
                                     bad = YES;
                                   CFRelease(sb);
                                 }
                               }];
  }
  dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
  if (xfer) {
    VTPixelTransferSessionInvalidate(xfer);
    CFRelease(xfer);
  }
  if (!expLive(gen)) {
    [reader cancelReading];
    [writer cancelWriting];
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    recPost(@"export-cancelled", totalMs, 0, 0, orig, 0, 0, @"", dst, nil);
    return;
  }
  if (bad || reader.status == AVAssetReaderStatusFailed) {
    NSLog(@"PinShot export: %@ %@", reader.error, writer.error);
    [reader cancelReading];
    [writer cancelWriting];
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    recPost(@"export-error", totalMs, 0, 0, orig, 0, 0, @"", dst, @"压缩编码失败");
    return;
  }
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  uint64_t bytes = writer.status == AVAssetWriterStatusCompleted ? fileSize(dst) : 0;
  if (bytes == 0) {
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    recPost(@"export-error", totalMs, 0, 0, orig, 0, 0, @"", dst, @"压缩编码失败");
    return;
  }
  copyFile(dst);
  recPost(@"exported", totalMs, 0, bytes, orig, 100, ain != nil, cname, dst, nil);
}

// An animated GIF of the recording, `gfps` pictures a second at ow × oh (a picture the same as the last one made into
// a longer showing of it).
static void exportGif(int gen, NSString *src, NSString *dst, int ow, int oh, int gfps, int64_t totalMs, uint64_t orig) {
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:src] options:nil];
  NSError *err = nil;
  AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
  AVAssetTrack *vt = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  if (!reader || !vt) {
    recPost(@"export-error", totalMs, 0, 0, orig, 0, 0, @"GIF", dst, @"读取源视频失败");
    return;
  }
  AVAssetReaderTrackOutput *vout = [AVAssetReaderTrackOutput
      assetReaderTrackOutputWithTrack:vt
                       outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)}];
  vout.alwaysCopiesSampleData = NO;
  [reader addOutput:vout];
  if (![reader startReading]) {
    recPost(@"export-error", totalMs, 0, 0, orig, 0, 0, @"GIF", dst, @"解码源视频失败");
    return;
  }
  [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
  [NSFileManager.defaultManager createDirectoryAtPath:dst.stringByDeletingLastPathComponent
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  size_t expect = (size_t)MAX(1, totalMs / 1000.0 * gfps + 2);
  CGImageDestinationRef out = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:dst],
                                                              (__bridge CFStringRef)UTTypeGIF.identifier, expect, NULL);
  if (!out) {
    [reader cancelReading];
    recPost(@"export-error", totalMs, 0, 0, orig, 0, 0, @"GIF", dst, @"无法创建 GIF 文件");
    return;
  }
  CGImageDestinationSetProperties(out, (__bridge CFDictionaryRef) @{
    (id)kCGImagePropertyGIFDictionary : @{(id)kCGImagePropertyGIFLoopCount : @0}
  });
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  size_t stride = (size_t)ow * 4;
  NSMutableData *cur = [NSMutableData dataWithLength:stride * oh];
  NSData *pending = nil;  // the picture waiting to be put in: its time grows while the next are the same
  long pendingAt = 0;  // (its time, in hundredths of a second: each picture's showing rounded from its exact times)
  double step = 1.0 / gfps, next = 0, total = MAX(0.001, totalMs / 1000.0);
  int lastPct = -1, steps = 0;
  BOOL cancelled = NO;
  void (^put)(NSData *, int) = ^(NSData *px, int delayCs) {
    CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)px);
    CGImageRef img = CGImageCreate(ow, oh, 8, 32, stride, space,
                                   kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst, dp, NULL,
                                   NO, kCGRenderingIntentDefault);
    CGDataProviderRelease(dp);
    double d = MAX(2, delayCs) / 100.0;
    CGImageDestinationAddImage(out, img, (__bridge CFDictionaryRef) @{
      (id)kCGImagePropertyGIFDictionary :
          @{(id)kCGImagePropertyGIFDelayTime : @(d), (id)kCGImagePropertyGIFUnclampedDelayTime : @(d)}
    });
    CGImageRelease(img);
  };
  CMSampleBufferRef sb;
  while ((sb = [vout copyNextSampleBuffer])) {
    @autoreleasepool {
      if (!expLive(gen)) {
        CFRelease(sb);
        cancelled = YES;
        break;
      }
      double t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb));
      CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
      // (the frame shown at each of the GIF's times: the last one at or before it)
      while (pb && t + 1e-6 >= next && next < total) {
        CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        CGContextRef c = CGBitmapContextCreate(cur.mutableBytes, ow, oh, 8, stride, space,
                                               kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst);
        CGDataProviderRef dp =
            CGDataProviderCreateWithData(NULL, CVPixelBufferGetBaseAddress(pb),
                                         CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb), NULL);
        CGImageRef img = CGImageCreate(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 8, 32,
                                       CVPixelBufferGetBytesPerRow(pb), space,
                                       kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst, dp,
                                       NULL, NO, kCGRenderingIntentDefault);
        CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
        CGContextDrawImage(c, CGRectMake(0, 0, ow, oh), img);
        CGImageRelease(img);
        CGDataProviderRelease(dp);
        CGContextRelease(c);
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        if (!pending || ![pending isEqualToData:cur]) {
          long at = lround(next * 100);
          if (pending)
            put(pending, (int)(at - pendingAt));
          pending = [cur copy];
          pendingAt = at;
        }
        steps++;
        next = steps * step;
      }
      CFRelease(sb);
      int pct = (int)MIN(99, t / total * 100);
      if (pct != lastPct) {
        lastPct = pct;
        recPost(@"exporting", totalMs, 0, 0, orig, pct, 0, @"GIF", dst, nil);
      }
    }
  }
  if (!cancelled && !expLive(gen))
    cancelled = YES;
  BOOL ok = NO;
  if (!cancelled) {
    if (pending)
      put(pending, (int)MAX(2, lround(total * 100) - pendingAt));
    ok = reader.status != AVAssetReaderStatusFailed && pending && CGImageDestinationFinalize(out);
  } else
    [reader cancelReading];
  CFRelease(out);
  CGColorSpaceRelease(space);
  if (cancelled) {
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    recPost(@"export-cancelled", totalMs, 0, 0, orig, 0, 0, @"GIF", dst, nil);
    return;
  }
  uint64_t bytes = ok ? fileSize(dst) : 0;
  if (!bytes) {
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    recPost(@"export-error", totalMs, 0, 0, orig, 0, 0, @"GIF", dst, @"生成 GIF 失败");
    return;
  }
  copyFile(dst);
  recPost(@"exported", totalMs, 0, bytes, orig, 100, 0, @"GIF", dst, nil);
}

int32_t ps_rec_export(moonbit_bytes_t dest_path, int32_t fmt, int32_t quality, int32_t max_side, int32_t gif_fps) {
  if (atomic_load(&expRunning) || !masterPath)
    return 0;
  NSString *dst = utf8(dest_path);
  if (!dst.length)
    return 0;
  NSString *src = masterPath, *mcodec = masterCodec;
  int64_t totalMs = masterMs;
  uint64_t orig = masterBytes;
  int sw = masterW, sh = masterH, fps = masterFps, audio = masterAudio;
  if (fmt == 3)
    fmt = 0;  // (no AV1 encoder on a Mac: ps_rec_has_av1 says so, the panel never asks)
  int gfps = gif_fps <= 0 ? 15 : gif_fps;
  int ow, oh;
  scaledDims(sw, sh, max_side, &ow, &oh);
  int gen = atomic_fetch_add(&expGen, 1) + 1;
  atomic_store(&expRunning, 1);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      BOOL sameCodec = (fmt == 0) == [mcodec hasPrefix:@"HEVC"];
      if (fmt != 2 && quality == 0 && ow == sw && oh == sh && sameCodec) {
        // (the recording is already this: copied as it is)
        [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
        [NSFileManager.defaultManager createDirectoryAtPath:dst.stringByDeletingLastPathComponent
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
        if ([NSFileManager.defaultManager copyItemAtPath:src toPath:dst error:nil]) {
          copyFile(dst);
          recPost(@"exported", totalMs, 0, fileSize(dst), orig, 100, audio, mcodec, dst, nil);
        } else
          recPost(@"export-error", totalMs, 0, 0, orig, 0, 0, @"", dst, @"保存文件失败");
      } else if (fmt == 2)
        exportGif(gen, src, dst, ow, oh, gfps, totalMs, orig);
      else
        exportMp4(gen, src, dst, fmt, quality, ow, oh, fps, totalMs, orig);
    }
    atomic_store(&expRunning, 0);
  });
  return 1;
}

// The export under way called off: its half file deleted by its worker, the recording kept ({"state":
// "export-cancelled"} told once it has stopped).
void ps_rec_export_cancel(void) { atomic_fetch_add(&expGen, 1); }

int32_t ps_rec_reuse(moonbit_bytes_t src_path, moonbit_bytes_t dst_path) {
  NSString *src = utf8(src_path), *dst = utf8(dst_path);
  if (!src.length || fileSize(src) == 0)
    return 0;
  if (!dst.length || [src isEqual:dst]) {
    copyFile(src);
    return 1;
  }
  [NSFileManager.defaultManager createDirectoryAtPath:dst.stringByDeletingLastPathComponent
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
  if (![NSFileManager.defaultManager copyItemAtPath:src toPath:dst error:nil])
    return -1;
  copyFile(dst);
  return 1;
}

int32_t ps_rec_has_av1(void) { return 0; }

moonbit_bytes_t ps_rec_preview(void) { return ps_data(masterPreview); }

void ps_rec_end(void) {
  frameHide();
  drawRecording = NO;
  R.prepared = NO;
  drawSync();
  R.session++;
  atomic_fetch_add(&expGen, 1);
  if (recorder)
    [recorder finish:YES];
  NSString *p = masterPath;
  masterPath = nil;
  masterBytes = 0;
  masterPreview = nil;
  if (p) {
    // (an export of it still reading lets go first: deleted once nothing exports)
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      while (atomic_load(&expRunning))
        usleep(20000);
      [NSFileManager.defaultManager removeItemAtPath:p error:nil];
    });
  }
}

void ps_rec_exclude(int32_t wid) {
  NSWindow *w = mb_app_window_of(wid);
  if (!w)
    return;
  mb_app_window_clear(wid);
  if (!excluded)
    excluded = [NSMutableSet set];
  [excluded addObject:@(w.windowNumber)];
  if (!getenv("PINSHOT_REC_SHOW"))
    w.sharingType = NSWindowSharingNone;
}

// (Windows' a window made next drawn on nothing: here ps_rec_exclude makes the panel so as it is placed)
void ps_next_win_clear(void) {}
