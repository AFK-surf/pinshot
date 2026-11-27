#import <Cocoa/Cocoa.h>
#import "moonbit.h"

NSWindow *mb_app_window_of(int wid);
void mb_app_window_clear(int wid);
void mb_app_window_round(int wid, double radius);
void ps_post(NSDictionary *event);
moonbit_bytes_t ps_data(NSData *data);
moonbit_bytes_t ps_string(NSString *string);
double ps_now_ms(void);
NSURL *ps_app_data(void);
NSScreen *ps_capture_screen(void);
NSScreen *ps_mouse_screen(void);
CGDirectDisplayID ps_display_id(NSScreen *screen);
NSRect ps_screen_pixels(NSScreen *screen, NSRect frame);
NSRect ps_screen_points(NSScreen *screen, NSRect pixels);
void ps_capture_ask(void);
void ps_bmp_header(uint8_t h[54], int32_t w, int32_t hh);
