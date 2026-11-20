#import "mac_platform.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>

static BOOL pending, captureOpen;
static NSData *png;
static NSMutableData *rgba;
static int width, height;
static double elapsed;
static NSScreen *capturedScreen;
static NSRect bounds;
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

// Each operation uses its display's origin in desktop points, with pixel offsets within it.
// The inverse takes the same display, including when its origin is negative.
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
  png = nil;
  rgba = nil;
  windows = nil;
  width = height = 0;
}
void ps_capture_open(int on) { captureOpen = on != 0; }

static NSString *windowList(SCDisplay *display, NSArray<SCWindow *> *items, CGFloat k) {
  NSMutableString *list = [NSMutableString string];
  for (SCWindow *w in items) {
    if (w.windowLayer != 0 || !w.isOnScreen ||
        w.owningApplication.processID == NSProcessInfo.processInfo.processIdentifier)
      continue;
    CGRect r = CGRectIntersection(display.frame, w.frame);
    if (CGRectIsNull(r) || r.size.width < 1 || r.size.height < 1)
      continue;
    [list appendFormat:@"%.0f,%.0f,%.0f,%.0f\n", (r.origin.x - display.frame.origin.x) * k,
                       (r.origin.y - display.frame.origin.y) * k, r.size.width * k, r.size.height * k];
  }
  return list;
}

static BOOL keepImage(CGImageRef image) {
  if (!image)
    return NO;
  width = (int)CGImageGetWidth(image);
  height = (int)CGImageGetHeight(image);
  rgba = [NSMutableData dataWithLength:(size_t)width * height * 4];
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(rgba.mutableBytes, width, height, 8, (size_t)width * 4, space,
                                           kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(space);
  if (!ctx)
    return NO;
  CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), image);
  CGContextRelease(ctx);
  NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
  png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  return png != nil;
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
      NSString *list = windowList(display, content.windows, scale);
      [SCScreenshotManager captureImageWithFilter:filter configuration:cfg
          completionHandler:^(CGImageRef image, NSError *err) { finish(image, list, err); }];
      return;
    }
    finish(NULL, nil, error);
  };
  [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES completionHandler:available];
}

void ps_capture_ask(void) { capture(YES, ^(BOOL ok) { (void)ok; }); }
int ps_capture_now(void) {
  __block BOOL finished = NO, success = NO;
  capture(NO, ^(BOOL ok) {
    success = ok;
    finished = YES;
  });
  // The command-line benchmark runs before NSApplication owns the event loop.
  while (!finished) {
    @autoreleasepool {
      [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
  }
  return success;
}
moonbit_bytes_t ps_capture_info(void) {
  return ps_string(png ? [NSString stringWithFormat:@"%.0f,%.0f,%d,%d,%.0f,%.2f,sck", bounds.origin.x,
                                                    bounds.origin.y, width, height, scale * 96, elapsed]
                       : @"");
}
moonbit_bytes_t ps_capture_take(void) { return ps_data(png); }
moonbit_bytes_t ps_windows(void) { return ps_string(windows); }
// (whether a window's part shows where the pointer is: Windows' question; the Mac lists windows alone, no parts, so a
// window listed after another and inside it is behind it: never)
int ps_window_shows(int of, int i, int x, int y) {
  (void)of;
  (void)i;
  (void)x;
  (void)y;
  return 0;
}
int ps_pixel(int x, int y) {
  if (!rgba || x < 0 || y < 0 || x >= width || y >= height)
    return -1;
  const uint8_t *p = (const uint8_t *)rgba.bytes + ((size_t)y * width + x) * 4;
  return p[0] << 16 | p[1] << 8 | p[2];
}
int ps_mean(int x, int y, int cell) {
  uint64_t r = 0, g = 0, b = 0, n = 0;
  for (int j = MAX(y, 0); j < MIN(y + cell, height); j++)
    for (int i = MAX(x, 0); i < MIN(x + cell, width); i++) {
      int c = ps_pixel(i, j);
      r += c >> 16;
      g += (c >> 8) & 255;
      b += c & 255;
      n++;
    }
  return n ? (int)((r / n) << 16 | (g / n) << 8 | b / n) : 0x808080;
}
