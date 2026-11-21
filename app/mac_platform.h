#import <Cocoa/Cocoa.h>
#import "moonbit.h"

NSWindow *mb_app_window_of(int wid);
void mb_app_window_clear(int wid);
void mb_app_window_round(int wid, double radius);
void ps_post(NSDictionary *event);
moonbit_bytes_t ps_data(NSData *data);
moonbit_bytes_t ps_string(NSString *string);
double ps_now_ms(void);
NSScreen *ps_capture_screen(void);
NSScreen *ps_mouse_screen(void);
CGDirectDisplayID ps_display_id(NSScreen *screen);
NSRect ps_screen_pixels(NSScreen *screen, NSRect frame);
NSRect ps_screen_points(NSScreen *screen, NSRect pixels);
void ps_capture_ask(void);

// Refcounted raw BGRA pixel buffer handed to mbui by address ("MBRAWPTR", matching platform_win.c's Held).
typedef struct PSHeld PSHeld;
PSHeld *ps_held_new(uint8_t *pixels);
void ps_held_name(PSHeld *h, const uint8_t *at, int32_t w, int32_t hh, int32_t pitch, uint8_t out[44]);
void ps_held_drop(PSHeld *h);
