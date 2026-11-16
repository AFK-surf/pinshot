// Cross-platform host boundary for PinShot.
// On Windows implemented in `platform_win.c`; on macOS in `platform_mac.m`.

///|
fn cstr(s : String) -> Bytes {
  @utf8.encode(s + "\u{0}")
}

///|
extern "C" fn ps_args_str() -> Bytes = "ps_args_str"

///|
extern "C" fn ps_capture_screen() -> Int = "ps_capture_screen"

///|
extern "C" fn ps_capture_info() -> Bytes = "ps_capture_info"

///|
extern "C" fn ps_capture_bmp() -> Bytes = "ps_capture_bmp"

///|
extern "C" fn ps_enum_windows() -> Bytes = "ps_enum_windows"

///|
extern "C" fn ps_setup_popup(x : Int, y : Int, w : Int, h : Int, topmost : Int) -> Int = "ps_setup_popup"

///|
extern "C" fn ps_show_popup(x : Int, y : Int, w : Int, h : Int) -> Unit = "ps_show_popup"

///|
extern "C" fn ps_hide_window() -> Unit = "ps_hide_window"

///|
extern "C" fn ps_set_opacity(alpha : Int) -> Unit = "ps_set_opacity"

///|
extern "C" fn ps_set_topmost(on : Int) -> Unit = "ps_set_topmost"

///|
extern "C" fn ps_now_us() -> Int64 = "ps_now_us"

///|
extern "C" fn ps_tray_start() -> Int = "ps_tray_start"

///|
extern "C" fn ps_poll_action() -> Int = "ps_poll_action"

///|
#borrow(png, name)
extern "C" fn ps_save_png_dialog(png : Bytes, name : Bytes) -> Int = "ps_save_png_dialog"

///|
#borrow(png)
extern "C" fn ps_launch_pin(png : Bytes, x : Int, y : Int, w : Int, h : Int) -> Int = "ps_launch_pin"

///|
#borrow(path)
extern "C" fn ps_read_file(path : Bytes) -> Bytes = "ps_read_file"

///|
#borrow(path)
extern "C" fn ps_delete_file(path : Bytes) -> Unit = "ps_delete_file"

///|
extern "C" fn ps_clipboard_png() -> Bytes = "ps_clipboard_png"

///|
extern "C" fn ps_release_capture() -> Unit = "ps_release_capture"

///|
extern "C" fn ps_trim_memory() -> Unit = "ps_trim_memory"

///|
extern "C" fn ps_encode_crop_png(x : Int, y : Int, w : Int, h : Int) -> Bytes = "ps_encode_crop_png"

///|
#borrow(rgba)
extern "C" fn ps_encode_rgba_png(w : Int, h : Int, rgba : FixedArray[Byte]) -> Bytes = "ps_encode_rgba_png"

///|
extern "C" fn ps_read_settings() -> Bytes = "ps_read_settings"

///|
#borrow(data)
extern "C" fn ps_write_settings(data : Bytes) -> Int = "ps_write_settings"

///|
extern "C" fn ps_get_autostart() -> Int = "ps_get_autostart"

///|
extern "C" fn ps_set_autostart(on : Int) -> Int = "ps_set_autostart"

///|
extern "C" fn ps_default_save_dir() -> Bytes = "ps_default_save_dir"

///|
#borrow(png, dir)
extern "C" fn ps_auto_save_png(png : Bytes, dir : Bytes) -> Int = "ps_auto_save_png"

///|
extern "C" fn ps_notify_reload_settings() -> Unit = "ps_notify_reload_settings"
