#import "mac_platform.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <stdatomic.h>

struct PSHeld {
  uint8_t *pixels;
  atomic_int refs;
};

static void held_hook(void *ctx, int op) {
  PSHeld *h = (PSHeld *)ctx;
  if (!h)
    return;
  if (op)
    atomic_fetch_add(&h->refs, 1);
  else
    ps_held_drop(h);
}

PSHeld *ps_held_new(uint8_t *pixels) {
  PSHeld *h = (PSHeld *)calloc(1, sizeof *h);
  if (!h)
    return NULL;
  h->pixels = pixels;
  atomic_init(&h->refs, 1);
  return h;
}

void ps_held_name(PSHeld *h, const uint8_t *at, int32_t w, int32_t hh, int32_t pitch, uint8_t out[44]) {
  uint64_t a = (uint64_t)(uintptr_t)at, fn = (uint64_t)(uintptr_t)held_hook, ctx = (uint64_t)(uintptr_t)h;
  memcpy(out, "MBRAWPTR", 8);
  memcpy(out + 8, &a, 8);
  memcpy(out + 16, &w, 4);
  memcpy(out + 20, &hh, 4);
  memcpy(out + 24, &pitch, 4);
  memcpy(out + 28, &fn, 8);
  memcpy(out + 36, &ctx, 8);
}

void ps_held_drop(PSHeld *h) {
  if (!h)
    return;
  if (atomic_fetch_sub(&h->refs, 1) == 1) {
    free(h->pixels);
    free(h);
  }
}

static BOOL pending, captureOpen;
static PSHeld *capHeld;
static uint8_t *capBits;
static int width, height, pitch;
static double elapsed;
static NSScreen *capturedScreen;
static NSRect bounds;
static NSRect workBounds;
static CGFloat scale;
static NSString *windows;

CGDirectDisplayID ps_display_id(NSScreen *s) {
  return [s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
}

NSScreen *ps_mouse_screen(void) {
  NSPoint p = NSEvent.mouseLocation;
  for (NSScreen *s in NSScreen.screens)
    if (NSPointInRect(p, s.frame))
      return s;
  return NSScreen.mainScreen;
}

NSRect ps_screen_pixels(NSScreen *s, NSRect f) {
  CGRect origin = CGDisplayBounds(ps_display_id(s));
  CGFloat k = s.backingScaleFactor;
  return NSMakeRect(origin.origin.x + (NSMinX(f) - NSMinX(s.frame)) * k,
                    origin.origin.y + (NSMaxY(s.frame) - NSMaxY(f)) * k, NSWidth(f) * k, NSHeight(f) * k);
}
NSRect ps_screen_points(NSScreen *s, NSRect p) {
  CGRect origin = CGDisplayBounds(ps_display_id(s));
  CGFloat k = s.backingScaleFactor;
  return NSMakeRect(NSMinX(s.frame) + (NSMinX(p) - origin.origin.x) / k,
                    NSMaxY(s.frame) - (NSMaxY(p) - origin.origin.y) / k, NSWidth(p) / k, NSHeight(p) / k);
}

NSScreen *ps_capture_screen(void) { return capturedScreen; }

void ps_capture_release(void) {
  capturedScreen = nil;
  if (capHeld) {
    PSHeld *h = capHeld;
    capHeld = NULL;
    capBits = NULL;
    ps_held_drop(h);
  }
  windows = nil;
  width = height = pitch = 0;
}
void ps_capture_open(int on) { captureOpen = on != 0; }

static NSString *windowList(CGDirectDisplayID displayID, CGFloat k) {
  NSMutableString *list = [NSMutableString string];
  CGRect displayBounds = CGDisplayBounds(displayID);
  pid_t ownPID = NSProcessInfo.processInfo.processIdentifier;
  // CGWindowListCopyWindowInfo returns windows in strict WindowServer front-to-back Z-order with alpha & layer,
  // unlike SCShareableContent.windows which is not guaranteed Z-ordered and lacks alpha filtering.
  CFArrayRef raw = CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  if (!raw)
    return list;
  NSArray<NSDictionary *> *items = CFBridgingRelease(raw);
  for (NSDictionary *info in items) {
    NSNumber *layerNum = info[(id)kCGWindowLayer];
    if (!layerNum)
      continue;
    int layer = layerNum.intValue;
    if (layer < 0 || layer >= 20)
      continue;
    NSNumber *pidNum = info[(id)kCGWindowOwnerPID];
    if (pidNum && pidNum.intValue == ownPID)
      continue;
    NSNumber *alphaNum = info[(id)kCGWindowAlpha];
    if (alphaNum && alphaNum.doubleValue <= 0.01)
      continue;
    NSDictionary *boundsDict = info[(id)kCGWindowBounds];
    CGRect wf = CGRectZero;
    if (!boundsDict || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)boundsDict, &wf))
      continue;
    if (wf.size.width < 8 || wf.size.height < 8)
      continue;
    CGRect r = CGRectIntersection(displayBounds, wf);
    if (CGRectIsNull(r) || r.size.width < 8 || r.size.height < 8)
      continue;
    [list appendFormat:@"%.0f,%.0f,%.0f,%.0f\n",
                       (r.origin.x - displayBounds.origin.x) * k,
                       (r.origin.y - displayBounds.origin.y) * k,
                       r.size.width * k, r.size.height * k];
  }
  return list;
}

static BOOL keepImage(CGImageRef image) {
  if (!image)
    return NO;
  int w = (int)CGImageGetWidth(image);
  int h = (int)CGImageGetHeight(image);
  if (w <= 0 || h <= 0)
    return NO;
  int stride = w * 4;
  uint8_t *buf = (uint8_t *)malloc((size_t)stride * h);
  if (!buf)
    return NO;
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(buf, (size_t)w, (size_t)h, 8, (size_t)stride, space,
                                           (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  CGColorSpaceRelease(space);
  if (!ctx) {
    free(buf);
    return NO;
  }
  CGContextSetBlendMode(ctx, kCGBlendModeCopy);
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
  CGContextRelease(ctx);
  PSHeld *held = ps_held_new(buf);
  if (!held) {
    free(buf);
    return NO;
  }
  capHeld = held;
  capBits = buf;
  width = w;
  height = h;
  pitch = stride;
  return YES;
}

static void permissionHelp(void) {
  BOOL zh = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];
  NSAlert *alert = [NSAlert new];
  alert.messageText = zh ? @"允许 PinShot 截取屏幕" : @"Allow PinShot to capture your screen";
  alert.informativeText = zh ? @"在「屏幕与系统音频录制」中开启 PinShot。如果列表里没有它，点＋并选择当前的 "
                               @"PinShot.app。授权后请退出并重新打开应用。"
                             : @"Enable PinShot in Screen & System Audio Recording. If it is missing, use + "
                               @"to select this PinShot.app. Quit and reopen the app after granting access.";
  [alert addButtonWithTitle:zh ? @"打开系统设置" : @"Open System Settings"];
  [alert addButtonWithTitle:zh ? @"取消" : @"Cancel"];
  [NSApp activateIgnoringOtherApps:YES];
  if ([alert runModal] == NSAlertFirstButtonReturn) {
    [NSWorkspace.sharedWorkspace
        openURL:[NSURL URLWithString:
                           @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
  }
}

static void capture(BOOL interactive, void (^done)(BOOL)) {
  if (pending || captureOpen) {
    done(NO);
    return;
  }
  pending = YES;
  if (!CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess()) {
    if (interactive)
      permissionHelp();
    pending = NO;
    done(NO);
    return;
  }
  ps_capture_release();
  double start = ps_now_ms();
  NSScreen *s = ps_mouse_screen();
  capturedScreen = s;
  CGDirectDisplayID displayID = ps_display_id(s);
  bounds = ps_screen_pixels(s, s.frame);
  scale = s.backingScaleFactor;
  NSRect vf = s.visibleFrame;
  workBounds = NSMakeRect((NSMinX(vf) - NSMinX(s.frame)) * scale,
                          (NSMaxY(s.frame) - NSMaxY(vf)) * scale,
                          NSWidth(vf) * scale, NSHeight(vf) * scale);
  NSString *snapWindows = windowList(displayID, scale);
  void (^finish)(CGImageRef, NSString *, NSError *) = ^(CGImageRef image, NSString *list, NSError *error) {
    if (image)
      CGImageRetain(image);
    dispatch_async(dispatch_get_main_queue(), ^{
      BOOL ok = keepImage(image);
      if (image)
        CGImageRelease(image);
      elapsed = ps_now_ms() - start;
      pending = NO;
      if (ok) {
        windows = list;
        if (interactive) {
          captureOpen = YES;
          ps_post(@{
            @"do" : @"prepare",
            @"x" : @(bounds.origin.x),
            @"y" : @(bounds.origin.y),
            @"w" : @(width),
            @"h" : @(height),
            @"wx" : @(lrint(workBounds.origin.x)),
            @"wy" : @(lrint(workBounds.origin.y)),
            @"ww" : @(lrint(workBounds.size.width)),
            @"wh" : @(lrint(workBounds.size.height)),
            @"dpi" : @(scale * 96),
            @"t" : @(start)
          });
          ps_post(@{@"do" : @"capture"});
        }
      } else if (interactive) {
        ps_capture_release();
        NSLog(@"PinShot capture: %@", error);
        ps_post(@{@"do" : @"capture-failed"});
      }
      done(ok);
    });
  };
  void (^available)(SCShareableContent *, NSError *) = ^(SCShareableContent *content, NSError *error) {
    for (SCDisplay *display in content.displays) {
      if (display.displayID != displayID) continue;
      SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
      SCStreamConfiguration *cfg = [SCStreamConfiguration new];
      cfg.width = (size_t)NSWidth(bounds);
      cfg.height = (size_t)NSHeight(bounds);
      cfg.showsCursor = NO;
      [SCScreenshotManager captureImageWithFilter:filter configuration:cfg
          completionHandler:^(CGImageRef image, NSError *err) { finish(image, snapWindows, err); }];
      return;
    }
    finish(NULL, nil, error);
  };
  [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES completionHandler:available];
}

void ps_capture_ask(void) { capture(YES, ^(BOOL ok) { (void)ok; }); }
int ps_capture_now(void) {
  __block BOOL finished = NO, success = NO;
  capture(NO, ^(BOOL ok) {
    success = ok;
    finished = YES;
  });
  while (!finished) {
    @autoreleasepool {
      [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
  }
  return success;
}
moonbit_bytes_t ps_capture_info(void) {
  return ps_string(capHeld ? [NSString stringWithFormat:@"%.0f,%.0f,%d,%d,%.0f,%.2f,sck", bounds.origin.x,
                                                        bounds.origin.y, width, height, scale * 96, elapsed]
                           : @"");
}
moonbit_bytes_t ps_capture_take(void) {
  if (!capHeld || !capBits || width <= 0 || height <= 0)
    return moonbit_make_bytes(0, 0);
  uint8_t d[44];
  ps_held_name(capHeld, capBits, width, height, pitch, d);
  moonbit_bytes_t b = moonbit_make_bytes(44, 0);
  memcpy(b, d, 44);
  return b;
}
moonbit_bytes_t ps_windows(void) { return ps_string(windows); }
int ps_window_shows(int of, int i, int x, int y) {
  (void)of;
  (void)i;
  (void)x;
  (void)y;
  return 0;
}
int ps_pixel(int x, int y) {
  if (!capBits || x < 0 || y < 0 || x >= width || y >= height)
    return -1;
  const uint8_t *p = capBits + (size_t)y * pitch + (size_t)x * 4;
  return (p[2] << 16) | (p[1] << 8) | p[0];
}
int ps_mean(int x, int y, int cell) {
  if (!capBits)
    return 0x808080;
  int x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
  int x1 = x + cell > width ? width : x + cell, y1 = y + cell > height ? height : y + cell;
  if (x1 <= x0 || y1 <= y0)
    return 0x808080;
  int step = cell >= 24 ? 4 : (cell >= 8 ? 2 : 1);
  unsigned r = 0, g = 0, b = 0, n = 0;
  for (int yy = y0; yy < y1; yy += step) {
    const uint8_t *p = capBits + (size_t)yy * pitch + (size_t)x0 * 4;
    for (int xx = x0; xx < x1; xx += step, p += 4 * step) {
      b += p[0];
      g += p[1];
      r += p[2];
      n++;
    }
  }
  unsigned qr = r / n / 4 * 4 + 2, qg = g / n / 4 * 4 + 2, qb = b / n / 4 * 4 + 2;
  return (int)((qr << 16) | (qg << 8) | qb);
}
