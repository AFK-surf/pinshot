#import "mac_platform.h"
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
#import <sys/file.h>
#import <mach/mach.h>

extern void mb_post(const char *, const char *, size_t, const uint8_t *, size_t);
static NSStatusItem *statusItem;
static BOOL testing(void) { return getenv("PINSHOT_TEST") != NULL; }
static NSString *commandName(void) {
  return testing() ? @"org.motion-space.pinshot.test.command" : @"org.motion-space.pinshot.command";
}

moonbit_bytes_t ps_data(NSData *data) {
  moonbit_bytes_t bytes = moonbit_make_bytes((int)data.length, 0);
  if (data.length)
    memcpy(bytes, data.bytes, data.length);
  return bytes;
}
moonbit_bytes_t ps_string(NSString *s) { return ps_data([s dataUsingEncoding:NSUTF8StringEncoding]); }
static NSString *str(moonbit_bytes_t s) { return [NSString stringWithUTF8String:(char *)s]; }
static NSString *lines(moonbit_bytes_t s) {
  return [[NSString alloc] initWithBytes:s length:Moonbit_array_length(s) encoding:NSUTF8StringEncoding];
}
void ps_post(NSDictionary *event) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
  mb_post("ps", data.bytes, data.length, NULL, 0);
}
double ps_now_ms(void) { return NSProcessInfo.processInfo.systemUptime * 1000; }
static NSURL *directory(NSSearchPathDirectory kind) {
  NSURL *base = [NSFileManager.defaultManager URLsForDirectory:kind inDomains:NSUserDomainMask].firstObject;
  return [base URLByAppendingPathComponent:@"PinShot" isDirectory:YES];
}
static NSURL *appData(void) {
  NSURL *dir = directory(NSApplicationSupportDirectory);
  if (testing())
    dir = [[dir URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"PinShot-test"];
  [NSFileManager.defaultManager createDirectoryAtURL:dir
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil];
  return dir;
}

@interface PSMenuActions : NSObject
@property(copy) NSString *chosen;
@end
@implementation PSMenuActions
- (void)item:(NSMenuItem *)sender {
  self.chosen = sender.representedObject;
}
- (void)command:(NSNotification *)note {
  if ([note.object isEqual:@"capture"])
    ps_capture_ask();
  else if ([note.object isEqual:@"settings"] || [note.object isEqual:@"quit"])
    ps_post(@{@"do" : @"menu", @"item" : note.object});
}
- (void)tray:(NSMenuItem *)sender {
  ps_post(@{@"do" : @"menu", @"item" : sender.representedObject});
}
- (void)click:(id)sender {
  if (NSApp.currentEvent.type == NSEventTypeRightMouseUp ||
      (NSApp.currentEvent.modifierFlags & NSEventModifierFlagControl)) {
    NSMenu *menu = [sender menu];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, 0) inView:sender];
  } else
    ps_capture_ask();
}
@end
static PSMenuActions *actions;
static NSMenu *makeMenu(NSString *spec, BOOL tray) {
  NSMenu *menu = [NSMenu new];
  menu.autoenablesItems = NO;
  for (NSString *line in [spec componentsSeparatedByString:@"\n"]) {
    if ([line isEqual:@"-"]) {
      [menu addItem:NSMenuItem.separatorItem];
      continue;
    }
    NSArray<NSString *> *fields = [line componentsSeparatedByString:@"\t"];
    if (fields.count < 2)
      continue;
    NSString *title = [fields[1] stringByReplacingOccurrencesOfString:@"\b" withString:@"    "];
    NSMenuItem *item = [menu addItemWithTitle:title
                                       action:tray ? @selector(tray:) : @selector(item:)
                                keyEquivalent:@""];
    item.target = actions;
    item.representedObject = fields[0];
    if (fields.count > 2) {
      item.state = [fields[2] isEqual:@"c"] ? NSControlStateValueOn : NSControlStateValueOff;
      item.enabled = ![fields[2] isEqual:@"g"];
    }
  }
  return menu;
}
int ps_start(int again) {
  [NSApplication sharedApplication];
  actions = [PSMenuActions new];
  NSURL *lock = [appData() URLByAppendingPathComponent:@"session.lock"];
  int fd = open(lock.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0)
    return 0;
  NSDistributedNotificationCenter *center = NSDistributedNotificationCenter.defaultCenter;
  if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
    close(fd);
    [center postNotificationName:commandName()
                          object:again == 2   ? @"quit"
                                 : again == 1 ? @"settings"
                                              : @"capture"
                        userInfo:nil
              deliverImmediately:YES];
    return 0;
  }
  if (again == 2) {
    close(fd);
    return 0;
  }
  [center addObserver:actions
                selector:@selector(command:)
                    name:commandName()
                  object:nil
      suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
  if (testing())
    return 1;
  statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
  statusItem.button.image = [NSImage imageWithSystemSymbolName:@"camera.viewfinder"
                                      accessibilityDescription:@"PinShot"];
  statusItem.button.toolTip = @"PinShot";
  statusItem.button.target = actions;
  statusItem.button.action = @selector(click:);
  [statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
  return 1;
}
int ps_tray_on(void) { return statusItem != nil; }
void ps_set_menu(moonbit_bytes_t spec) { statusItem.button.menu = makeMenu(lines(spec), YES); }
moonbit_bytes_t ps_popup_menu(int wid, moonbit_bytes_t spec) {
  actions.chosen = nil;
  [makeMenu(lines(spec), NO) popUpMenuPositioningItem:nil atLocation:NSEvent.mouseLocation inView:nil];
  return ps_string(actions.chosen);
}
void ps_tray_note(moonbit_bytes_t title, moonbit_bytes_t message) {
  NSAlert *alert = [NSAlert new];
  alert.messageText = str(title);
  alert.informativeText = str(message);
  [alert addButtonWithTitle:@"OK"];
  dispatch_async(dispatch_get_main_queue(), ^{
    [alert runModal];
    ps_post(@{@"do" : @"menu", @"item" : @"settings"});
  });
}
moonbit_bytes_t ps_args(void) {
  NSArray *args = NSProcessInfo.processInfo.arguments;
  return ps_string([[args subarrayWithRange:NSMakeRange(1, args.count - 1)] componentsJoinedByString:@"\n"]);
}
void mb_app_reopen(void) { ps_capture_ask(); }
void ps_quit(void) { [NSApp terminate:nil]; }
int ps_ui_chinese(void) { return [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"]; }

static OSStatus hitKey(EventHandlerCallRef next, EventRef event, void *user) {
  EventHotKeyID key;
  if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(key), NULL, &key) !=
      noErr)
    return eventNotHandledErr;
  if (key.signature != 'PnSh')
    return eventNotHandledErr;
  if (key.id == 1)
    ps_capture_ask();
  else
    ps_post(@{@"do" : key.id == 2 ? @"pin-clipboard" : @"pins"});
  return noErr;
}
int ps_hotkey(int which, int mods, int vk) {
  if (testing())
    return 1;
  static EventHotKeyRef keys[4];
  static EventHandlerRef handler;
  if (which < 1 || which > 3)
    return 0;
  if (keys[which]) {
    UnregisterEventHotKey(keys[which]);
    keys[which] = NULL;
  }
  if (!vk)
    return 1;
  if (!handler) {
    EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
    if (InstallApplicationEventHandler(hitKey, 1, &spec, NULL, &handler) != noErr)
      return 0;
  }
  UInt32 code;
  switch (vk) {
  case 'A':
    code = kVK_ANSI_A;
    break;
  case '1':
    code = kVK_ANSI_1;
    break;
  case '2':
    code = kVK_ANSI_2;
    break;
  case 0x70:
    code = kVK_F1;
    break;
  case 0x71:
    code = kVK_F2;
    break;
  case 0x72:
    code = kVK_F3;
    break;
  default:
    return 0;
  }
  UInt32 flags = (mods & 1 ? optionKey : 0) | (mods & 2 ? controlKey : 0) | (mods & 4 ? shiftKey : 0) |
                 (mods & 8 ? cmdKey : 0);
  EventHotKeyID id = {'PnSh', (UInt32)which};
  return RegisterEventHotKey(code, flags, id, GetApplicationEventTarget(), 0, &keys[which]) == noErr;
}

extern void mb_app_manage_window(int wid);
extern void mb_host_window_drag(void);
static NSRunningApplication *previousApp;
static NSMapTable<NSWindow *, NSScreen *> *windowScreens;
int ps_own(int wid, int top) {
  NSWindow *w = mb_app_window_of(wid);
  if (!w)
    return 0;
  mb_app_manage_window(wid);
  if (wid) {
    w.alphaValue = 1;
    w.ignoresMouseEvents = NO;
  }
  if (!windowScreens)
    windowScreens = [NSMapTable weakToStrongObjectsMapTable];
  [windowScreens setObject:(ps_capture_screen() ?: ps_mouse_screen()) forKey:w];
  w.styleMask = NSWindowStyleMaskBorderless;
  w.minSize = NSMakeSize(1, 1);
  w.hasShadow = NO;
  w.level = top ? (wid ? NSFloatingWindowLevel : NSScreenSaverWindowLevel) : NSNormalWindowLevel;
  w.collectionBehavior =
      NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
  if (wid) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *name in @[ NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification ]) {
      [tokens addObject:[center addObserverForName:name
                                            object:w
                                             queue:nil
                                        usingBlock:^(NSNotification *n) {
                                          ps_post(@{
                                            @"do" : @"active",
                                            @"wid" : @(wid),
                                            @"on" : @([n.name isEqual:NSWindowDidBecomeKeyNotification])
                                          });
                                        }]];
    }
    [tokens addObject:[center addObserverForName:NSWindowWillCloseNotification
                                          object:w
                                           queue:nil
                                      usingBlock:^(NSNotification *n) {
                                        for (id token in tokens)
                                          [NSNotificationCenter.defaultCenter removeObserver:token];
                                        [tokens removeAllObjects];
                                      }]];
  }
  return 1;
}
void ps_shadow(int wid) { mb_app_window_of(wid).hasShadow = YES; }
void ps_place(int wid, int x, int y, int width, int height, int show, int focus) {
  NSWindow *w = mb_app_window_of(wid);
  NSScreen *s = wid ? [windowScreens objectForKey:w] : ps_capture_screen();
  [w setFrame:ps_screen_points(s ?: ps_mouse_screen(), NSMakeRect(x, y, width, height)) display:YES];
  if (show && focus) {
    if (!wid && !NSApp.active)
      previousApp = NSWorkspace.sharedWorkspace.frontmostApplication;
    [NSApp activateIgnoringOtherApps:YES];
    [w makeKeyAndOrderFront:nil];
  } else if (show)
    [w orderFrontRegardless];
}
void ps_center(int wid, int width, int height) {
  NSScreen *s = ps_mouse_screen();
  NSRect f = s.visibleFrame;
  NSWindow *w = mb_app_window_of(wid);
  w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  NSRect frame = [w frameRectForContentRect:NSMakeRect(0, 0, width, height)];
  height = MIN(NSHeight(frame), NSHeight(f));
  width = MIN(NSWidth(frame), NSWidth(f));
  [w setFrame:NSMakeRect(NSMidX(f) - width / 2, NSMidY(f) - height / 2, width, height) display:YES];
  [NSApp activateIgnoringOtherApps:YES];
  [w makeKeyAndOrderFront:nil];
}
void ps_move_window(int wid) { mb_host_window_drag(); }
void ps_hide(int wid) {
  NSWindow *w = mb_app_window_of(wid);
  BOOL restore = !wid && w.keyWindow;
  [w orderOut:nil];
  if (!wid) {
    if (restore && previousApp)
      [previousApp activateWithOptions:0];
    previousApp = nil;
  }
}
void ps_cloak(int wid, int on) {
  NSWindow *w = mb_app_window_of(wid);
  w.alphaValue = on ? 0 : 1;
  w.ignoresMouseEvents = on;
}
void ps_topmost(int wid, int on, int front) {
  NSWindow *w = mb_app_window_of(wid);
  w.level = on ? NSFloatingWindowLevel : NSNormalWindowLevel;
  if (front)
    [w orderFrontRegardless];
}
void ps_toast_place(int wid, int width, int height) {
  NSWindow *w = mb_app_window_of(wid);
  NSPoint p = NSEvent.mouseLocation;
  NSRect f = ps_mouse_screen().visibleFrame;
  [w setFrame:NSMakeRect(MIN(MAX(NSMinX(f), p.x - width / 2), NSMaxX(f) - width),
                         MIN(MAX(NSMinY(f), p.y - height - 12), NSMaxY(f) - height), width, height)
      display:YES];
  w.ignoresMouseEvents = YES;
  [w orderFrontRegardless];
}
void ps_opacity(int wid, int alpha) { mb_app_window_of(wid).alphaValue = alpha / 255.0; }
void ps_let_close(int wid) {} // mbui delivers NSWindowWillClose once, for either close path.
moonbit_bytes_t ps_window_rect(int wid) {
  NSWindow *w = mb_app_window_of(wid);
  NSScreen *s = w.screen ?: ps_mouse_screen();
  if (!w)
    return ps_string(nil);
  [windowScreens setObject:s forKey:w];
  NSRect r = ps_screen_pixels(s, w.frame);
  return ps_string([NSString stringWithFormat:@"%.0f,%.0f,%.0f,%.0f,%.0f", NSMinX(r), NSMinY(r), NSWidth(r),
                                              NSHeight(r), 96 * s.backingScaleFactor]);
}
int ps_shift_down(void) { return (NSEvent.modifierFlags & NSEventModifierFlagShift) != 0; }
moonbit_bytes_t ps_pointer(void) {
  NSPoint p = NSEvent.mouseLocation;
  NSRect r = ps_screen_pixels(ps_capture_screen() ?: ps_mouse_screen(), NSMakeRect(p.x, p.y, 0, 0));
  return ps_string([NSString stringWithFormat:@"%.0f,%.0f", NSMinX(r), NSMinY(r)]);
}
void ps_gpu_flush(void) {} // Windows' D3D deferred-release hook.
moonbit_bytes_t ps_memory(void) {
  task_vm_info_data_t info = {};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
  return ps_string([NSString stringWithFormat:@"%llu,%llu", info.resident_size, info.phys_footprint]);
}
moonbit_bytes_t ps_data_dir(void) { return ps_string(appData().path); }
moonbit_bytes_t ps_pictures_dir(void) { return ps_string(directory(NSPicturesDirectory).path); }
moonbit_bytes_t ps_read_file(moonbit_bytes_t path) {
  return ps_data([NSData dataWithContentsOfFile:str(path)]);
}
int ps_write_file(moonbit_bytes_t path, moonbit_bytes_t bytes) {
  NSString *dest = str(path);
  [NSFileManager.defaultManager createDirectoryAtPath:dest.stringByDeletingLastPathComponent
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  return [[NSData dataWithBytes:bytes length:Moonbit_array_length(bytes)] writeToFile:dest atomically:YES];
}
moonbit_bytes_t ps_save_dialog(int wid, moonbit_bytes_t dir, moonbit_bytes_t name) {
  NSSavePanel *panel = [NSSavePanel savePanel];
  panel.directoryURL = [NSURL fileURLWithPath:str(dir) isDirectory:YES];
  panel.nameFieldStringValue = str(name);
  return ps_string([panel runModal] == NSModalResponseOK ? panel.URL.path : nil);
}
void ps_reveal(moonbit_bytes_t path) {
  NSURL *url = [NSURL fileURLWithPath:str(path)];
  BOOL folder;
  if (![NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&folder]) {
    [NSFileManager.defaultManager createDirectoryAtURL:url
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    folder = YES;
  }
  if (folder)
    [NSWorkspace.sharedWorkspace openURL:url];
  else
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ url ]];
}
moonbit_bytes_t ps_stamp(void) {
  NSDateFormatter *fmt = [NSDateFormatter new];
  fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  fmt.dateFormat = @"yyyyMMdd-HHmmss";
  return ps_string([fmt stringFromDate:NSDate.date]);
}
void ps_log(moonbit_bytes_t line) {
  FILE *f = fopen([appData() URLByAppendingPathComponent:@"pinshot.log"].fileSystemRepresentation, "a");
  if (f) {
    fprintf(f, "%s %s\n", NSDate.date.description.UTF8String, (char *)line);
    fclose(f);
  }
}
int ps_autostart(void) { return SMAppService.mainAppService.status == SMAppServiceStatusEnabled; }
int ps_set_autostart(int on) {
  SMAppService *service = SMAppService.mainAppService;
  BOOL changed = on ? [service registerAndReturnError:nil] : [service unregisterAndReturnError:nil];
  if (on && service.status == SMAppServiceStatusRequiresApproval)
    [SMAppService openSystemSettingsLoginItems];
  return changed && (ps_autostart() == on);
}
moonbit_bytes_t ps_clipboard_image(void) {
  NSPasteboard *board = NSPasteboard.generalPasteboard;
  NSData *png = [board dataForType:NSPasteboardTypePNG];
  if (!png) {
    NSData *tiff = [board dataForType:NSPasteboardTypeTIFF];
    if (!tiff)
      return ps_data(nil);
    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
    png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  }
  return ps_data(png);
}
void ps_shutter(void) {
  static NSSound *sound;
  if (!sound)
    sound = [[NSSound alloc] initWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"shutter"
                                                                         withExtension:@"wav"]
                                       byReference:YES];
  [sound stop];
  [sound play];
}
void ps_set_capture_keep(int32_t keep) { (void)keep; }
int32_t ps_ocr(int32_t id, moonbit_bytes_t png) {
  (void)id;
  (void)png;
  return 0;
}
moonbit_bytes_t ps_ocr_now(moonbit_bytes_t png) {
  (void)png;
  return ps_string(@"no-ocr\t\t0\n");
}
