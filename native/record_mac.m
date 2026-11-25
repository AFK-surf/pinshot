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

static NSData *previewBmp(CVPixelBufferRef pb) {
  if (!pb)
    return nil;
  OSType fmt = CVPixelBufferGetPixelFormatType(pb);
  BOOL isNv12 = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  if (!isNv12 && fmt != kCVPixelFormatType_32BGRA)
    return nil;
  BOOL fullRange = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  int w = (int)CVPixelBufferGetWidth(pb), h = (int)CVPixelBufferGetHeight(pb);
  const uint8_t *bgra = isNv12 ? NULL : (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
  size_t pitch = isNv12 ? 0 : CVPixelBufferGetBytesPerRow(pb);
  const uint8_t *yPlane = isNv12 ? (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0) : NULL;
  const uint8_t *uvPlane = isNv12 ? (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1) : NULL;
  size_t yPitch = isNv12 ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : 0;
  size_t uvPitch = isNv12 ? CVPixelBufferGetBytesPerRowOfPlane(pb, 1) : 0;
  if (w <= 0 || h <= 0 || (isNv12 && (!yPlane || !uvPlane)) || (!isNv12 && !bgra)) {
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return nil;
  }
  const int pw = 352, ph = 368;
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
      if (isNv12) {
        for (int yy = y0; yy < y1; yy++) {
          const uint8_t *yr = yPlane + (size_t)yy * yPitch;
          const uint8_t *uvr = uvPlane + (size_t)(yy >> 1) * uvPitch;
          for (int xx = x0; xx < x1; xx++, cnt++) {
            int Y = (int)yr[xx];
            int U = (int)uvr[(xx & ~1)] - 128;
            int V = (int)uvr[(xx & ~1) + 1] - 128;
            int r, g, b;
            if (fullRange) {
              r = Y + ((403 * V + 128) >> 8);
              g = Y - ((48 * U + 120 * V + 128) >> 8);
              b = Y + ((475 * U + 128) >> 8);
            } else {
              int c = 298 * (Y - 16);
              r = (c + 459 * V + 128) >> 8;
              g = (c - 55 * U - 136 * V + 128) >> 8;
              b = (c + 541 * U + 128) >> 8;
            }
            sr += (uint32_t)(r < 0 ? 0 : (r > 255 ? 255 : r));
            sg += (uint32_t)(g < 0 ? 0 : (g > 255 ? 255 : g));
            sb += (uint32_t)(b < 0 ? 0 : (b > 255 ? 255 : b));
          }
        }
      } else {
        for (int yy = y0; yy < y1; yy++) {
          const uint8_t *s = bgra + (size_t)yy * pitch;
          for (int xx = x0; xx < x1; xx++, cnt++) {
            sb += s[xx * 4];
            sg += s[xx * 4 + 1];
            sr += s[xx * 4 + 2];
          }
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

static struct {
  BOOL prepared;
  int x, y, w, h;
  int mx, my, mw, mh;
  int session;
  BOOL inputShow;
} R;
static NSScreen *recScreen;
static NSMutableSet<NSNumber *> *excluded;

static NSRect regionPoints(void) {
  return ps_screen_points(recScreen, NSMakeRect(R.x, R.y, R.w, R.h));
}

static void postRect(void) {
  NSString *s =
      [NSString stringWithFormat:@"{\"do\":\"rec-rect\",\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d}", R.x, R.y, R.w, R.h];
  mb_post("ps", s.UTF8String, strlen(s.UTF8String), NULL, 0);
}

static NSColor *rgb(int c) {
  return [NSColor colorWithSRGBRed:((c >> 16) & 255) / 255.0 green:((c >> 8) & 255) / 255.0 blue:(c & 255) / 255.0
                             alpha:1];
}

@interface PSRecFrameView : NSView
@property NSScreen *screen;
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

static const CGFloat framePad = 10;
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

static NSBezierPath *ps_superellipse_path(NSRect r, CGFloat rad) {
  CGFloat w = NSWidth(r), h = NSHeight(r);
  CGFloat room = MIN(w, h) * 0.5;
  CGFloat rc = MAX(0.0, MIN(rad, room));
  if (rc <= 0.01)
    return [NSBezierPath bezierPathWithRect:r];
  CGFloat s = MAX(0.0, MIN(1.0, (room - rc) / (0.25 * rc)));
  CGFloat rr = MIN(rc * (1.0 + 0.25 * s), room);
  CGFloat kappa = 0.55228475 + (0.7621 - 0.55228475) * s;
  CGFloat c = rr * (1.0 - kappa);
  CGFloat x0 = NSMinX(r), y0 = NSMinY(r), x1 = NSMaxX(r), y1 = NSMaxY(r);
  NSBezierPath *p = [NSBezierPath bezierPath];
  [p moveToPoint:NSMakePoint(x0 + rr, y0)];
  [p lineToPoint:NSMakePoint(x1 - rr, y0)];
  [p curveToPoint:NSMakePoint(x1, y0 + rr)
      controlPoint1:NSMakePoint(x1 - c, y0)
      controlPoint2:NSMakePoint(x1, y0 + c)];
  [p lineToPoint:NSMakePoint(x1, y1 - rr)];
  [p curveToPoint:NSMakePoint(x1 - rr, y1)
      controlPoint1:NSMakePoint(x1, y1 - c)
      controlPoint2:NSMakePoint(x1 - c, y1)];
  [p lineToPoint:NSMakePoint(x0 + rr, y1)];
  [p curveToPoint:NSMakePoint(x0, y1 - rr)
      controlPoint1:NSMakePoint(x0 + c, y1)
      controlPoint2:NSMakePoint(x0, y1 - c)];
  [p lineToPoint:NSMakePoint(x0, y0 + rr)];
  [p curveToPoint:NSMakePoint(x0 + rr, y0)
      controlPoint1:NSMakePoint(x0, y0 + c)
      controlPoint2:NSMakePoint(x0 + c, y0)];
  [p closePath];
  return p;
}

@implementation PSRecFrameView {
  int dragX, dragY;
  NSPoint dragFrom;
  int fromX, fromY, fromW, fromH;
}
- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e {
  return YES;
}
- (NSRect)borderRect {
  NSRect b = NSInsetRect(self.bounds, framePad - 2, framePad - 2);
  NSRect s = self.screen.frame;
  NSRect onScreen = [self.window convertRectFromScreen:NSInsetRect(s, 2, 2)];
  onScreen = [self convertRect:onScreen fromView:nil];
  return NSIntersectionRect(b, onScreen);
}
- (NSBezierPath *)roundRect:(NSRect)r {
  CGFloat rad = MIN(6, MIN(NSWidth(r), NSHeight(r)) * 0.5 * 0.35);
  return ps_superellipse_path(r, rad);
}
- (void)drawRect:(NSRect)dirty {
  NSRect r = [self borderRect];
  if (NSIsEmptyRect(r))
    return;
  CGContextRef c = NSGraphicsContext.currentContext.CGContext;
  NSColor *col = [self.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (self.handles) {
    NSBezierPath *grip = [self roundRect:r];
    grip.lineWidth = 16;
    [[NSColor colorWithWhite:0 alpha:0.01] setStroke];
    [grip stroke];
  }
  CGFloat halfW = self.handles ? 0.95 : 1.1;
  CGContextSaveGState(c);
  CGContextSetShadowWithColor(c, CGSizeZero, 6, [col colorWithAlphaComponent:0.55].CGColor);
  NSBezierPath *p = [self roundRect:r];
  p.lineWidth = halfW * 2;
  [[col colorWithAlphaComponent:0.28] setStroke];
  [p stroke];
  CGContextRestoreGState(c);
  p.lineWidth = (halfW + 1.35) * 2;
  [[NSColor colorWithWhite:0 alpha:0.32] setStroke];
  [p stroke];
  p.lineWidth = halfW * 2;
  if (self.dashed) {
    CGFloat dash[] = {7, 6};
    [p setLineDash:dash count:2 phase:0];
  }
  [[col colorWithAlphaComponent:0.9] setStroke];
  [p stroke];
  if (!self.handles)
    return;
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
  if (R.w >= 54 * recScreen.backingScaleFactor) {
    CGFloat mx = NSMidX(r);
    [marks moveToPoint:NSMakePoint(mx - 7, y0)];
    [marks lineToPoint:NSMakePoint(mx + 7, y0)];
    [marks moveToPoint:NSMakePoint(mx - 7, y1)];
    [marks lineToPoint:NSMakePoint(mx + 7, y1)];
  }
  if (R.h >= 54 * recScreen.backingScaleFactor) {
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

static PSRecFrameWindow *frameWindowMade(void) {
  PSRecFrameWindow *w = [[PSRecFrameWindow alloc] initWithContentRect:NSMakeRect(0, 0, 16, 16)
                                                            styleMask:NSWindowStyleMaskBorderless |
                                                                      NSWindowStyleMaskNonactivatingPanel
                                                              backing:NSBackingStoreBuffered
                                                                defer:NO];
  w.opaque = NO;
  w.backgroundColor = NSColor.clearColor;
  w.hasShadow = NO;
  w.releasedWhenClosed = NO;
  w.level = NSFloatingWindowLevel;
  w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary |
                         NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
  w.ignoresMouseEvents = YES;
  w.contentView = [[PSRecFrameView alloc] initWithFrame:NSMakeRect(0, 0, 16, 16)];
  return w;
}

static void frameShow(NSColor *color, BOOL dashed, BOOL handles) {
  const char *cl = getenv("PINSHOT_TEST_CLOAKED");
  if (cl && cl[0])
    return;
  if (!frameWin) {
    frameWin = frameWindowMade();
    if (!getenv("PINSHOT_REC_SHOW"))
      frameWin.sharingType = NSWindowSharingNone;
    frameView = (PSRecFrameView *)frameWin.contentView;
    [excluded addObject:@(frameWin.windowNumber)];
  }
  frameView.screen = recScreen;
  frameView.color = color;
  frameView.dashed = dashed;
  frameView.handles = handles;
  frameWin.ignoresMouseEvents = !handles;
  framePlace();
  [frameWin orderFrontRegardless];
}

NSWindow *ps_region_frame(NSWindow *w, NSScreen *s, NSRect px, int c, int dashed) {
  if (!w)
    w = frameWindowMade();
  PSRecFrameView *v = (PSRecFrameView *)w.contentView;
  v.screen = s;
  v.color = rgb(c);
  v.dashed = dashed != 0;
  v.handles = NO;
  [w setFrame:NSInsetRect(ps_screen_points(s, px), -framePad, -framePad) display:YES];
  v.needsDisplay = YES;
  [w orderFrontRegardless];
  return w;
}

void ps_region_frame_close(NSWindow *w) {
  [w orderOut:nil];
  [w close];
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

typedef struct {
  NSPoint at;
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
    NSBezierPath *shade = ps_superellipse_path(NSMakeRect(x, y + 2.5, w, ch), 8);
    [[NSColor colorWithWhite:0 alpha:95 / 255.0 * alpha] setFill];
    [shade fill];
    NSBezierPath *cap = ps_superellipse_path(NSMakeRect(x, y, w, ch), 8);
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

static BOOL drawShown;

static void drawSchedule(double now);

static void drawTick(void) {
  [drawTimer invalidate];
  drawTimer = nil;
  double now = ps_now_ms();
  int n = 0;
  for (int i = 0; i < rippleCount; i++)
    if (now < ripples[i].start + rippleMs)
      ripples[n++] = ripples[i];
  rippleCount = n;
  if (caps && now >= capsStart + keyHoldMs + keyFadeMs)
    caps = nil;
  if (!drawBusy(now)) {
    if (drawShown) {
      [drawWin orderOut:nil];
      drawShown = NO;
    }
    return;
  }
  if (!drawShown && drawWin) {
    [drawWin orderFrontRegardless];
    drawShown = YES;
  }
  drawView.needsDisplay = YES;
  drawSchedule(now);
}

static void drawSchedule(double now) {
  [drawTimer invalidate];
  drawTimer = nil;
  double delaySec = 0;
  if (rippleCount > 0) {
    delaySec = 1.0 / 60.0;
  } else if (caps) {
    double fadeAt = capsStart + keyHoldMs;
    delaySec = now >= fadeAt ? (1.0 / 60.0) : MAX(0.004, (fadeAt - now) / 1000.0);
  }
  if (delaySec > 0) {
    drawTimer = [NSTimer scheduledTimerWithTimeInterval:delaySec
                                                repeats:NO
                                                  block:^(NSTimer *t) {
                                                    (void)t;
                                                    drawTick();
                                                  }];
  }
}

static void drawWake(void) {
  if (!drawWin)
    return;
  if (!drawShown) {
    [drawWin orderFrontRegardless];
    drawShown = YES;
  }
  drawView.needsDisplay = YES;
  drawSchedule(ps_now_ms());
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
    drawShown = NO;
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
  if (drawShown)
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

@interface PSRecorder : NSObject <SCStreamOutput, SCStreamDelegate>
@end

static PSRecorder *recorder;
static atomic_int recRunning;
static atomic_int recPaused;

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
  dispatch_queue_t q;
  AVAssetWriter *writer;
  AVAssetWriterInput *vin, *ain;
  AVAssetWriterInputPixelBufferAdaptor *adaptor;
  NSString *path, *codec;
  BOOL hasAudio;
  BOOL started, stopping, failed;
  CMTime origin;
  double pausedTotal;
  double pauseBegan;
  BOOL wasPaused;
  CMTime lastPts;
  CVPixelBufferRef lastFrame;
  int frames;
  double startedAt;
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
  c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  c.colorSpaceName = kCGColorSpaceITUR_709;
  c.colorMatrix = kCGDisplayStreamYCbCrMatrix_ITU_R_709_2;
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

- (void)fail:(NSString *)why {
  dispatch_async(q, ^{
    if (self->failed || self->stopping)
      return;
    self->failed = YES;
    self->stopping = YES;
    [self->stream stopCaptureWithCompletionHandler:nil];
    self->stream = nil;
    [self->writer cancelWriting];
    self->writer = nil;
    self->vin = nil;
    self->ain = nil;
    self->adaptor = nil;
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
    self->stream = nil;
    [writer cancelWriting];
    self->writer = nil;
    self->vin = nil;
    self->ain = nil;
    self->adaptor = nil;
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
  self->stream = nil;
  [writer finishWritingWithCompletionHandler:^{
    BOOL ok = self->writer.status == AVAssetWriterStatusCompleted;
    uint64_t bytes = ok ? fileSize(self->path) : 0;
    self->writer = nil;
    self->vin = nil;
    self->ain = nil;
    self->adaptor = nil;
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

static atomic_int expGen;
static atomic_int expRunning;
static dispatch_group_t expGroup;

int32_t ps_rec_prepare(int32_t x, int32_t y, int32_t w, int32_t h) {
  static BOOL swept;
  if (atomic_load(&recRunning) || atomic_load(&expRunning) || recorder)
    return 0;
  if (!excluded)
    excluded = [NSMutableSet set];
  if (!swept) {
    swept = YES;
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

static BOOL expLive(int gen) { return atomic_load(&expGen) == gen; }

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
      AVVideoMaxKeyFrameIntervalKey : @(fps * 5),
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

typedef struct {
  uint16_t key;
  uint32_t cnt;
} PSGifHistEntry;

typedef struct {
  size_t lo, hi;
  uint8_t r0, r1, g0, g1, b0, b1;
  uint64_t pop;
} PSGifBox;

typedef struct {
  FILE *fp;
  int w, h;
  BOOL headerWritten;
  uint8_t globalPal[256 * 3];
  uint8_t globalLut[32768];
  int globalNcols;

  uint8_t *prevRgb;
  uint8_t *prevIdx;
  BOOL hasPending;
  int pendX, pendY, pendW, pendH;
  int pendDelayCs;
  BOOL pendLocalPal;
  uint8_t pendPal[256 * 3];
  uint8_t *pendIdx;
  size_t pendIdxLen, pendIdxCap;
  int framesWritten;

  int32_t htKey[8192];
  uint16_t htVal[8192];
  uint8_t *crop, *mask;
  size_t cropCap, maskCap;
} PSGifWriter;

static uint8_t gifLutOf(uint8_t lut[32768], const uint8_t pal[256 * 3], int ncols, uint32_t k) {
  uint8_t v = lut[k];
  if (v != 0xFF)
    return v;
  int r = (int)((k >> 10) & 31) * 255 / 31;
  int g = (int)((k >> 5) & 31) * 255 / 31;
  int b = (int)(k & 31) * 255 / 31;
  int bestI = 0, bestD = 1 << 30;
  for (int i = 0; i < ncols; i++) {
    int dr = r - (int)pal[i * 3 + 0];
    int dg = g - (int)pal[i * 3 + 1];
    int db = b - (int)pal[i * 3 + 2];
    int d = dr * dr * 2 + dg * dg * 4 + db * db;
    if (d < bestD) {
      bestD = d;
      bestI = i;
    }
  }
  lut[k] = (uint8_t)bestI;
  return (uint8_t)bestI;
}

static void gifFitBox(PSGifBox *bx, const PSGifHistEntry *entries) {
  bx->r0 = bx->g0 = bx->b0 = 31;
  bx->r1 = bx->g1 = bx->b1 = 0;
  bx->pop = 0;
  for (size_t i = bx->lo; i < bx->hi; i++) {
    uint16_t k = entries[i].key;
    uint8_t r = (uint8_t)((k >> 10) & 31);
    uint8_t g = (uint8_t)((k >> 5) & 31);
    uint8_t b = (uint8_t)(k & 31);
    if (r < bx->r0) bx->r0 = r;
    if (r > bx->r1) bx->r1 = r;
    if (g < bx->g0) bx->g0 = g;
    if (g > bx->g1) bx->g1 = g;
    if (b < bx->b0) bx->b0 = b;
    if (b > bx->b1) bx->b1 = b;
    bx->pop += entries[i].cnt;
  }
}

static int gifBuildPalette(const uint8_t *rgb, int nPixels, const uint8_t *mask, uint8_t pal[256 * 3],
                           uint8_t lut[32768]) {
  static const int MAX_COLORS = 255;
  uint32_t *hist = (uint32_t *)calloc(32768, sizeof(uint32_t));
  if (!hist) {
    memset(pal, 0, 256 * 3);
    memset(lut, 0, 32768);
    return 1;
  }
  for (int i = 0; i < nPixels; i++) {
    if (mask && !mask[i])
      continue;
    uint32_t r = rgb[i * 3 + 0] >> 3;
    uint32_t g = rgb[i * 3 + 1] >> 3;
    uint32_t b = rgb[i * 3 + 2] >> 3;
    hist[(r << 10) | (g << 5) | b]++;
  }
  size_t nEntries = 0;
  for (uint32_t k = 0; k < 32768; k++)
    if (hist[k])
      nEntries++;
  memset(pal, 0, 256 * 3);
  if (nEntries == 0) {
    free(hist);
    memset(lut, 0, 32768);
    return 1;
  }
  PSGifHistEntry *entries = (PSGifHistEntry *)malloc(nEntries * sizeof(PSGifHistEntry));
  size_t ei = 0;
  for (uint32_t k = 0; k < 32768; k++)
    if (hist[k])
      entries[ei++] = (PSGifHistEntry){(uint16_t)k, hist[k]};
  free(hist);

  PSGifBox boxes[255];
  int nBoxes = 1;
  boxes[0] = (PSGifBox){0, nEntries, 0, 31, 0, 31, 0, 31, 0};
  gifFitBox(&boxes[0], entries);

  while (nBoxes < MAX_COLORS) {
    int best = -1;
    uint64_t bestScore = 0;
    for (int i = 0; i < nBoxes; i++) {
      if (boxes[i].hi - boxes[i].lo < 2)
        continue;
      int dr = boxes[i].r1 - boxes[i].r0;
      int dg = boxes[i].g1 - boxes[i].g0;
      int db = boxes[i].b1 - boxes[i].b0;
      int span = dr > dg ? (dr > db ? dr : db) : (dg > db ? dg : db);
      if (span == 0)
        continue;
      uint64_t score = (uint64_t)span * boxes[i].pop;
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    if (best < 0)
      break;
    PSGifBox bx = boxes[best];
    int dr = bx.r1 - bx.r0, dg = bx.g1 - bx.g0, db = bx.b1 - bx.b0;
    int shift = (dg >= dr && dg >= db) ? 5 : (dr >= db ? 10 : 0);
    qsort_b(entries + bx.lo, bx.hi - bx.lo, sizeof(PSGifHistEntry), ^int(const void *pa, const void *pb) {
      int va = (((const PSGifHistEntry *)pa)->key >> shift) & 31;
      int vb = (((const PSGifHistEntry *)pb)->key >> shift) & 31;
      return va - vb;
    });
    uint64_t half = bx.pop / 2, acc = 0;
    size_t mid = bx.lo + 1;
    for (size_t i = bx.lo; i + 1 < bx.hi; i++) {
      acc += entries[i].cnt;
      mid = i + 1;
      if (acc >= half)
        break;
    }
    PSGifBox b1 = {bx.lo, mid, 0, 0, 0, 0, 0, 0, 0};
    PSGifBox b2 = {mid, bx.hi, 0, 0, 0, 0, 0, 0, 0};
    gifFitBox(&b1, entries);
    gifFitBox(&b2, entries);
    boxes[best] = b1;
    boxes[nBoxes++] = b2;
  }

  for (int i = 0; i < nBoxes; i++) {
    uint64_t sr = 0, sg = 0, sb = 0, cnt = 0;
    for (size_t j = boxes[i].lo; j < boxes[i].hi; j++) {
      uint16_t k = entries[j].key;
      uint64_t c = entries[j].cnt;
      sr += (((k >> 10) & 31) * 255 / 31) * c;
      sg += (((k >> 5) & 31) * 255 / 31) * c;
      sb += ((k & 31) * 255 / 31) * c;
      cnt += c;
    }
    pal[i * 3 + 0] = (uint8_t)(cnt ? sr / cnt : 0);
    pal[i * 3 + 1] = (uint8_t)(cnt ? sg / cnt : 0);
    pal[i * 3 + 2] = (uint8_t)(cnt ? sb / cnt : 0);
  }
  memset(lut, 0xFF, 32768);
  for (int i = 0; i < nBoxes; i++)
    for (size_t j = boxes[i].lo; j < boxes[i].hi; j++)
      lut[entries[j].key] = (uint8_t)i;
  free(entries);
  return nBoxes;
}

static BOOL gifOpen(PSGifWriter *g, NSString *path, int w, int h) {
  memset(g, 0, sizeof *g);
  g->fp = fopen(path.fileSystemRepresentation, "wb");
  if (!g->fp)
    return NO;
  g->w = w;
  g->h = h;
  size_t n = (size_t)w * h;
  g->prevRgb = (uint8_t *)calloc(n * 3, 1);
  g->prevIdx = (uint8_t *)malloc(n);
  if (!g->prevRgb || !g->prevIdx) {
    fclose(g->fp);
    g->fp = NULL;
    free(g->prevRgb);
    free(g->prevIdx);
    g->prevRgb = g->prevIdx = NULL;
    return NO;
  }
  memset(g->prevIdx, 255, n);
  return YES;
}

static void gifFree(PSGifWriter *g) {
  if (g->fp) {
    fclose(g->fp);
    g->fp = NULL;
  }
  free(g->prevRgb);
  free(g->prevIdx);
  free(g->pendIdx);
  free(g->crop);
  free(g->mask);
  g->prevRgb = g->prevIdx = g->pendIdx = g->crop = g->mask = NULL;
}

static void gifWriteU16(FILE *fp, uint16_t v) {
  uint8_t b[2] = {(uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF)};
  fwrite(b, 1, 2, fp);
}

static void gifWriteHeader(PSGifWriter *g) {
  fwrite("GIF89a", 1, 6, g->fp);
  gifWriteU16(g->fp, (uint16_t)g->w);
  gifWriteU16(g->fp, (uint16_t)g->h);
  fputc(0xF7, g->fp);
  fputc(0, g->fp);
  fputc(0, g->fp);
  fwrite(g->globalPal, 1, 256 * 3, g->fp);
  static const uint8_t netscape[] = {0x21, 0xFF, 0x0B, 'N', 'E', 'T', 'S', 'C', 'A', 'P', 'E', '2', '.', '0',
                                     0x03, 0x01, 0x00, 0x00, 0x00};
  fwrite(netscape, 1, sizeof netscape, g->fp);
  g->headerWritten = YES;
}

typedef struct {
  FILE *fp;
  uint8_t sub[256];
  int subLen;
  uint32_t bitBuf;
  int bitCnt;
} PSGifBits;

static inline void gifFlushSub(PSGifBits *b) {
  if (b->subLen > 0) {
    fputc(b->subLen, b->fp);
    fwrite(b->sub, 1, (size_t)b->subLen, b->fp);
    b->subLen = 0;
  }
}

static inline void gifEmitCode(PSGifBits *b, int code, int bits) {
  b->bitBuf |= ((uint32_t)code << b->bitCnt);
  b->bitCnt += bits;
  while (b->bitCnt >= 8) {
    b->sub[b->subLen++] = (uint8_t)(b->bitBuf & 0xFF);
    b->bitBuf >>= 8;
    b->bitCnt -= 8;
    if (b->subLen == 255)
      gifFlushSub(b);
  }
}

static void gifWriteLzw(PSGifWriter *g, const uint8_t *indices, size_t count) {
  const int minCodeSize = 8, clearCode = 256, eoiCode = 257;
  fputc(minCodeSize, g->fp);
  for (int i = 0; i < 8192; i++)
    g->htKey[i] = -1;
  PSGifBits bits = {g->fp, {0}, 0, 0, 0};
  int nextCode = eoiCode + 1, codeBits = minCodeSize + 1;
  gifEmitCode(&bits, clearCode, codeBits);
  if (count > 0) {
    int prefix = indices[0];
    for (size_t i = 1; i < count; i++) {
      int ch = indices[i];
      int32_t key = (prefix << 8) | ch;
      int slot = (int)(((uint32_t)key * 2654435761u) >> 19) & 8191;
      int found = -1;
      while (g->htKey[slot] != -1) {
        if (g->htKey[slot] == key) {
          found = g->htVal[slot];
          break;
        }
        slot = (slot + 1) & 8191;
      }
      if (found >= 0) {
        prefix = found;
      } else {
        gifEmitCode(&bits, prefix, codeBits);
        if (nextCode < 4096) {
          g->htKey[slot] = key;
          g->htVal[slot] = (uint16_t)nextCode++;
          if (nextCode > (1 << codeBits) && codeBits < 12)
            codeBits++;
        } else {
          gifEmitCode(&bits, clearCode, codeBits);
          for (int j = 0; j < 8192; j++)
            g->htKey[j] = -1;
          nextCode = eoiCode + 1;
          codeBits = minCodeSize + 1;
        }
        prefix = ch;
      }
    }
    gifEmitCode(&bits, prefix, codeBits);
  }
  gifEmitCode(&bits, eoiCode, codeBits);
  if (bits.bitCnt > 0) {
    bits.sub[bits.subLen++] = (uint8_t)(bits.bitBuf & 0xFF);
    if (bits.subLen == 255)
      gifFlushSub(&bits);
  }
  gifFlushSub(&bits);
  fputc(0, g->fp);
}

static void gifFlushPending(PSGifWriter *g) {
  if (!g->hasPending || !g->fp)
    return;
  if (!g->headerWritten)
    gifWriteHeader(g);
  uint16_t delay = (uint16_t)(g->pendDelayCs < 2 ? 2 : (g->pendDelayCs > 65535 ? 65535 : g->pendDelayCs));
  uint8_t gce[8] = {0x21, 0xF9, 0x04, 0x05, (uint8_t)(delay & 0xFF), (uint8_t)((delay >> 8) & 0xFF), 255, 0x00};
  fwrite(gce, 1, sizeof gce, g->fp);
  fputc(0x2C, g->fp);
  gifWriteU16(g->fp, (uint16_t)g->pendX);
  gifWriteU16(g->fp, (uint16_t)g->pendY);
  gifWriteU16(g->fp, (uint16_t)g->pendW);
  gifWriteU16(g->fp, (uint16_t)g->pendH);
  fputc(g->pendLocalPal ? 0x87 : 0x00, g->fp);
  if (g->pendLocalPal)
    fwrite(g->pendPal, 1, 256 * 3, g->fp);
  gifWriteLzw(g, g->pendIdx, g->pendIdxLen);
  g->hasPending = NO;
  g->framesWritten++;
}

static void gifExtendPendingDelay(PSGifWriter *g, int extraCs) {
  if (g->hasPending && extraCs > 0) {
    int total = g->pendDelayCs + extraCs;
    g->pendDelayCs = total > 65535 ? 65535 : total;
  }
}

static BOOL gifReservePend(PSGifWriter *g, size_t n) {
  if (n > g->pendIdxCap) {
    uint8_t *p = (uint8_t *)realloc(g->pendIdx, n);
    if (!p)
      return NO;
    g->pendIdx = p;
    g->pendIdxCap = n;
  }
  g->pendIdxLen = n;
  return YES;
}

static void gifAddFrame(PSGifWriter *g, const uint8_t *rgb, int delayCs) {
  if (!g->fp)
    return;
  static const int DIFF_THRESH = 18;
  int w = g->w, h = g->h, n = w * h;
  if (!g->headerWritten && !g->hasPending) {
    g->globalNcols = gifBuildPalette(rgb, n, NULL, g->globalPal, g->globalLut);
    g->pendX = 0;
    g->pendY = 0;
    g->pendW = w;
    g->pendH = h;
    g->pendDelayCs = delayCs;
    g->pendLocalPal = NO;
    if (!gifReservePend(g, (size_t)n))
      return;
    memcpy(g->prevRgb, rgb, (size_t)n * 3);
    for (int i = 0; i < n; i++) {
      uint32_t k = (((uint32_t)rgb[i * 3 + 0] >> 3) << 10) | (((uint32_t)rgb[i * 3 + 1] >> 3) << 5) |
                   ((uint32_t)rgb[i * 3 + 2] >> 3);
      uint8_t idx = gifLutOf(g->globalLut, g->globalPal, g->globalNcols, k);
      g->pendIdx[i] = idx;
      g->prevIdx[i] = idx;
    }
    g->hasPending = YES;
    return;
  }
  int x0 = w, y0 = h, x1 = -1, y1 = -1, changed = 0;
  uint64_t errSum = 0;
  for (int y = 0; y < h; y++) {
    const uint8_t *cur = rgb + (size_t)y * w * 3;
    const uint8_t *prv = g->prevRgb + (size_t)y * w * 3;
    const uint8_t *pidx = g->prevIdx + (size_t)y * w;
    for (int x = 0; x < w; x++) {
      int dr = abs((int)cur[x * 3 + 0] - (int)prv[x * 3 + 0]);
      int dg = abs((int)cur[x * 3 + 1] - (int)prv[x * 3 + 1]);
      int db = abs((int)cur[x * 3 + 2] - (int)prv[x * 3 + 2]);
      if (dr + dg + db <= DIFF_THRESH)
        continue;
      uint32_t k = (((uint32_t)cur[x * 3 + 0] >> 3) << 10) | (((uint32_t)cur[x * 3 + 1] >> 3) << 5) |
                   ((uint32_t)cur[x * 3 + 2] >> 3);
      uint8_t gidx = gifLutOf(g->globalLut, g->globalPal, g->globalNcols, k);
      int gerr = abs((int)cur[x * 3 + 0] - (int)g->globalPal[gidx * 3 + 0]) +
                 abs((int)cur[x * 3 + 1] - (int)g->globalPal[gidx * 3 + 1]) +
                 abs((int)cur[x * 3 + 2] - (int)g->globalPal[gidx * 3 + 2]);
      if (pidx[x] == gidx && gerr <= 24)
        continue;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
      changed++;
      errSum += (uint64_t)gerr;
    }
  }
  if (changed == 0 && g->hasPending && g->pendDelayCs + delayCs <= 500) {
    g->pendDelayCs += delayCs;
    return;
  }
  gifFlushPending(g);
  if (changed == 0) {
    g->pendX = 0;
    g->pendY = 0;
    g->pendW = 1;
    g->pendH = 1;
    g->pendDelayCs = delayCs;
    g->pendLocalPal = NO;
    if (!gifReservePend(g, 1))
      return;
    g->pendIdx[0] = 255;
    g->hasPending = YES;
    return;
  }
  int dw = x1 - x0 + 1, dh = y1 - y0 + 1;
  BOOL useLocal = (changed > 256 && (errSum / (uint64_t)changed) > 26);
  uint8_t localLut[32768];
  uint8_t *lut = g->globalLut;
  const uint8_t *lutPal = g->globalPal;
  int lutN = g->globalNcols;
  if (useLocal) {
    size_t cropNeed = (size_t)dw * dh * 3, maskNeed = (size_t)dw * dh;
    if (cropNeed > g->cropCap) {
      g->crop = (uint8_t *)realloc(g->crop, cropNeed);
      g->cropCap = cropNeed;
    }
    if (maskNeed > g->maskCap) {
      g->mask = (uint8_t *)realloc(g->mask, maskNeed);
      g->maskCap = maskNeed;
    }
    if (g->crop && g->mask) {
      for (int y = 0; y < dh; y++) {
        const uint8_t *cur = rgb + ((size_t)(y0 + y) * w + x0) * 3;
        const uint8_t *prv = g->prevRgb + ((size_t)(y0 + y) * w + x0) * 3;
        memcpy(g->crop + (size_t)y * dw * 3, cur, (size_t)dw * 3);
        for (int x = 0; x < dw; x++) {
          int d = abs((int)cur[x * 3 + 0] - (int)prv[x * 3 + 0]) + abs((int)cur[x * 3 + 1] - (int)prv[x * 3 + 1]) +
                  abs((int)cur[x * 3 + 2] - (int)prv[x * 3 + 2]);
          g->mask[(size_t)y * dw + x] = d > DIFF_THRESH ? 1 : 0;
        }
      }
      lutN = gifBuildPalette(g->crop, dw * dh, g->mask, g->pendPal, localLut);
      lut = localLut;
      lutPal = g->pendPal;
    } else {
      useLocal = NO;
    }
  }
  g->pendX = x0;
  g->pendY = y0;
  g->pendW = dw;
  g->pendH = dh;
  g->pendDelayCs = delayCs;
  g->pendLocalPal = useLocal;
  if (!gifReservePend(g, (size_t)dw * dh))
    return;
  for (int y = 0; y < dh; y++) {
    const uint8_t *cur = rgb + ((size_t)(y0 + y) * w + x0) * 3;
    uint8_t *prv = g->prevRgb + ((size_t)(y0 + y) * w + x0) * 3;
    uint8_t *pidx = g->prevIdx + ((size_t)(y0 + y) * w + x0);
    for (int x = 0; x < dw; x++) {
      int d = abs((int)cur[x * 3 + 0] - (int)prv[x * 3 + 0]) + abs((int)cur[x * 3 + 1] - (int)prv[x * 3 + 1]) +
              abs((int)cur[x * 3 + 2] - (int)prv[x * 3 + 2]);
      if (d <= DIFF_THRESH) {
        g->pendIdx[(size_t)y * dw + x] = 255;
      } else {
        uint32_t k = (((uint32_t)cur[x * 3 + 0] >> 3) << 10) | (((uint32_t)cur[x * 3 + 1] >> 3) << 5) |
                     ((uint32_t)cur[x * 3 + 2] >> 3);
        uint8_t idx = gifLutOf(lut, lutPal, lutN, k);
        if (!useLocal && pidx[x] == idx) {
          int gerr = abs((int)cur[x * 3 + 0] - (int)g->globalPal[idx * 3 + 0]) +
                     abs((int)cur[x * 3 + 1] - (int)g->globalPal[idx * 3 + 1]) +
                     abs((int)cur[x * 3 + 2] - (int)g->globalPal[idx * 3 + 2]);
          if (gerr <= 24) {
            g->pendIdx[(size_t)y * dw + x] = 255;
            continue;
          }
        }
        g->pendIdx[(size_t)y * dw + x] = idx;
        prv[x * 3 + 0] = cur[x * 3 + 0];
        prv[x * 3 + 1] = cur[x * 3 + 1];
        prv[x * 3 + 2] = cur[x * 3 + 2];
        pidx[x] = useLocal ? 255 : idx;
      }
    }
  }
  g->hasPending = YES;
}

static uint64_t gifFinish(PSGifWriter *g) {
  if (!g->fp)
    return 0;
  gifFlushPending(g);
  if (g->headerWritten)
    fputc(0x3B, g->fp);
  fflush(g->fp);
  off_t sz = ftello(g->fp);
  fclose(g->fp);
  g->fp = NULL;
  return sz > 0 ? (uint64_t)sz : 0;
}

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
  PSGifWriter gif;
  if (!gifOpen(&gif, dst, ow, oh)) {
    [reader cancelReading];
    recPost(@"export-error", totalMs, 0, 0, orig, 0, 0, @"GIF", dst, @"无法创建 GIF 文件");
    return;
  }
  uint8_t *rgbFrame = (uint8_t *)malloc((size_t)ow * oh * 3);
  if (!rgbFrame) {
    gifFree(&gif);
    [reader cancelReading];
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    recPost(@"export-error", totalMs, 0, 0, orig, 0, 0, @"GIF", dst, @"生成 GIF 失败");
    return;
  }
  double step = 1.0 / gfps;
  int stepCs = MAX(2, (100 + gfps / 2) / gfps);
  double nextWant = 0.0, prevTs = -1.0, total = MAX(0.001, totalMs / 1000.0);
  int lastPct = -1;
  BOOL cancelled = NO;
  CMSampleBufferRef sb;
  while ((sb = [vout copyNextSampleBuffer])) {
    if (!expLive(gen)) {
      CFRelease(sb);
      cancelled = YES;
      break;
    }
    double t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb));
    if (t + 1e-6 < nextWant) {
      CFRelease(sb);
      continue;
    }
    while (nextWant <= t + 1e-6)
      nextWant += step;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (pb) {
      CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
      const uint8_t *scan0 = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
      int sw = (int)CVPixelBufferGetWidth(pb), sh = (int)CVPixelBufferGetHeight(pb);
      size_t pitch = CVPixelBufferGetBytesPerRow(pb);
      if (ow == sw && oh == sh) {
        for (int y = 0; y < oh; y++) {
          const uint8_t *s = scan0 + (size_t)y * pitch;
          uint8_t *d = rgbFrame + (size_t)y * ow * 3;
          for (int x = 0; x < ow; x++) {
            d[x * 3 + 0] = s[x * 4 + 2];
            d[x * 3 + 1] = s[x * 4 + 1];
            d[x * 3 + 2] = s[x * 4 + 0];
          }
        }
      } else {
        for (int y = 0; y < oh; y++) {
          int y0 = y * sh / oh, y1 = MAX(y0 + 1, (y + 1) * sh / oh);
          if (y1 > sh)
            y1 = sh;
          uint8_t *d = rgbFrame + (size_t)y * ow * 3;
          for (int x = 0; x < ow; x++) {
            int x0 = x * sw / ow, x1 = MAX(x0 + 1, (x + 1) * sw / ow);
            if (x1 > sw)
              x1 = sw;
            uint32_t sr = 0, sg = 0, sbv = 0, cnt = 0;
            for (int yy = y0; yy < y1; yy++) {
              const uint8_t *s = scan0 + (size_t)yy * pitch;
              for (int xx = x0; xx < x1; xx++, cnt++) {
                sr += s[xx * 4 + 2];
                sg += s[xx * 4 + 1];
                sbv += s[xx * 4 + 0];
              }
            }
            d[x * 3 + 0] = (uint8_t)(sr / cnt);
            d[x * 3 + 1] = (uint8_t)(sg / cnt);
            d[x * 3 + 2] = (uint8_t)(sbv / cnt);
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
      if (prevTs >= 0.0 && t > prevTs) {
        int realCs = (int)lround((t - prevTs) * 100.0);
        if (realCs > stepCs)
          gifExtendPendingDelay(&gif, MIN(realCs - stepCs, 500));
      }
      prevTs = t;
      gifAddFrame(&gif, rgbFrame, stepCs);
    }
    CFRelease(sb);
    int pct = (int)MIN(98, t / total * 98.0);
    if (pct - lastPct >= 5) {
      lastPct = pct;
      recPost(@"exporting", totalMs, 0, 0, orig, pct, 0, @"GIF", dst, nil);
    }
  }
  if (!cancelled && !expLive(gen))
    cancelled = YES;
  uint64_t bytes = 0;
  if (cancelled) {
    [reader cancelReading];
    gifFree(&gif);
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
  } else {
    if (prevTs >= 0.0 && total > prevTs) {
      int tailCs = (int)lround((total - prevTs) * 100.0);
      if (tailCs > stepCs)
        gifExtendPendingDelay(&gif, MIN(tailCs - stepCs, 300));
    }
    if (reader.status != AVAssetReaderStatusFailed)
      bytes = gifFinish(&gif);
    gifFree(&gif);
  }
  free(rgbFrame);
  if (cancelled) {
    recPost(@"export-cancelled", totalMs, 0, 0, orig, 0, 0, @"GIF", dst, nil);
    return;
  }
  if (!bytes) {
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    recPost(@"export-error", totalMs, 0, 0, orig, 0, 0, @"GIF", dst, @"生成 GIF 失败");
    return;
  }
  copyFile(dst);
  recPost(@"exported", totalMs, 0, bytes, orig, 100, 0, @"GIF", dst, nil);
}

int32_t ps_rec_export(moonbit_bytes_t dest_path, int32_t fmt, int32_t quality, int32_t max_side, int32_t gif_fps) {
  if (!expGroup)
    expGroup = dispatch_group_create();
  if (atomic_load(&expRunning)) {
    if (dispatch_group_wait(expGroup, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0 ||
        atomic_load(&expRunning))
      return 0;
  }
  if (!masterPath)
    return 0;
  NSString *dst = utf8(dest_path);
  if (!dst.length)
    return 0;
  NSString *src = masterPath, *mcodec = masterCodec;
  int64_t totalMs = masterMs;
  uint64_t orig = masterBytes;
  int sw = masterW, sh = masterH, fps = masterFps, audio = masterAudio;
  if (fmt == 3)
    fmt = 0;
  int gfps = gif_fps <= 0 ? 15 : gif_fps;
  int ow, oh;
  scaledDims(sw, sh, max_side, &ow, &oh);
  int gen = atomic_fetch_add(&expGen, 1) + 1;
  atomic_store(&expRunning, 1);
  dispatch_group_enter(expGroup);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      BOOL sameCodec = (fmt == 0) == [mcodec hasPrefix:@"HEVC"];
      if (fmt != 2 && quality == 0 && ow == sw && oh == sh && sameCodec) {
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
    dispatch_group_leave(expGroup);
  });
  return 1;
}

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
  masterCodec = nil;
  masterBytes = 0;
  masterPreview = nil;
  recScreen = nil;
  [excluded removeAllObjects];
  if (p) {
    if (expGroup && atomic_load(&expRunning)) {
      dispatch_group_notify(expGroup, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [NSFileManager.defaultManager removeItemAtPath:p error:nil];
      });
    } else {
      [NSFileManager.defaultManager removeItemAtPath:p error:nil];
    }
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

void ps_next_win_clear(void) {}
