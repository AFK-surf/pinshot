// What PinShot asks of the system, and nothing of its UI: one set of calls, answered on Windows by platform_win.c (and
// on a Mac by a platform_mac.m of the same names). Text crosses as UTF-8 (paths ending in a NUL: cstr); what happens
// outside the frames (a shortcut, the icon, its menu, a window's close) comes on the channel "ps" (main.mbt).

///|
/// `s` as the native side reads a path or a name: UTF-8 ending in a NUL.
fn cstr(s : String) -> Bytes {
  @utf8.encode(s + "\u{0}")
}

///|
/// UTF-8 bytes as a string.
fn text_of(b : Bytes) -> String {
  @utf8.decode_lossy(b[:])
}

///|
/// The run begun: 1 it is the one run; 0 another runs (told `again`: 0 take the screen, 1 open the settings, 2 quit):
/// this one ends.
extern "C" fn ps_start(again : Int) -> Int = "ps_start"

///|
/// A note from the icon (the system's notification); clicked, it opens the settings.
#borrow(title, text)
extern "C" fn ps_tray_note(title : Bytes, text : Bytes) -> Unit = "ps_tray_note"

///|
extern "C" fn ps_shutter() -> Unit = "ps_shutter"

///|
extern "C" fn ps_shadow(wid : Int) -> Unit = "ps_shadow"

///|
/// Window `wid` moved with the pointer (the press under way: the system's move, as a title bar's), the press let go
/// of as the move ends.
extern "C" fn ps_move_window(wid : Int) -> Unit = "ps_move_window"

///|
/// Window `wid`, `w` by `h` points, under the pointer (kept on its monitor), its corners round, over the others,
/// shown without the keyboard.
extern "C" fn ps_toast_place(wid : Int, w : Int, h : Int) -> Unit = "ps_toast_place"

///|
/// Whether the icon is in the notification area.
extern "C" fn ps_tray_on() -> Int = "ps_tray_on"

///|
/// The run's arguments after the program's name, one a line.
extern "C" fn ps_args() -> Bytes = "ps_args"

///|
/// The run ended, its icon taken away first.
extern "C" fn ps_quit() -> Unit = "ps_quit"

///|
/// The icon's menu: "key\twords" lines, "-" a separator; each item's key is told back as it is chosen.
#borrow(lines)
extern "C" fn ps_set_menu(lines : Bytes) -> Unit = "ps_set_menu"

///|
/// A global shortcut (1 capture, 2 pin the clipboard, 3 show or hide the pins) set to `mods` (Alt 1, Ctrl 2, Shift 4,
/// Win 8) with `vk` (0: none): 1 it is ours, 0 another program has it.
extern "C" fn ps_hotkey(which : Int, mods : Int, vk : Int) -> Int = "ps_hotkey"

///|
/// The screen taken now (the monitor the pointer is on): 1 when taken.
extern "C" fn ps_capture_now() -> Int = "ps_capture_now"

///|
/// A capture asked for (the icon's menu): as the shortcut, told back as "prepare" and "capture".
extern "C" fn ps_capture_ask() -> Unit = "ps_capture_ask"

///|
/// Whether a capture is open (none other is taken meanwhile).
extern "C" fn ps_capture_open(on : Int) -> Unit = "ps_capture_open"

///|
/// A line in the run's log (pinshot.log in the settings' folder), its time before it.
#borrow(line)
extern "C" fn ps_log(line : Bytes) -> Unit = "ps_log"

///|
fn log(line : String) -> Unit {
  ps_log(cstr(line))
}

///|
/// What was taken: "x,y,w,h,dpi,ms"; "" none.
extern "C" fn ps_capture_info() -> Bytes = "ps_capture_info"

///|
/// Where the picture taken is, as mbui takes pixels kept elsewhere ("MBRAWPTR"...): empty where there is none. Its
/// pixels stay on the native side till ps_capture_release.
extern "C" fn ps_capture_take() -> Bytes = "ps_capture_take"

///|
/// The picture taken let go.
extern "C" fn ps_capture_release() -> Unit = "ps_capture_release"

///|
/// The colour of the pixel at (x, y) of the picture taken: 0xRRGGBB, -1 where there is none.
extern "C" fn ps_pixel(x : Int, y : Int) -> Int = "ps_pixel"

///|
/// The mean colour (0xRRGGBB) of the `cell` square at (x, y) of the picture taken.
extern "C" fn ps_mean(x : Int, y : Int, cell : Int) -> Int = "ps_mean"

///|
/// The windows on the monitor taken, the front first: "x,y,w,h" lines in its pixels (a window's parts after it).
extern "C" fn ps_windows() -> Bytes = "ps_windows"

///|
/// Window `wid` made one of PinShot's own: no frame, not on the taskbar, over the others where `topmost`.
extern "C" fn ps_own(wid : Int, topmost : Int) -> Int = "ps_own"

///|
/// Window `wid` at x, y, w by h (the screen's pixels); shown where `show`, taking the keyboard where `focus`.
extern "C" fn ps_place(wid : Int, x : Int, y : Int, w : Int, h : Int, show : Int, focus : Int) -> Unit = "ps_place"

///|
extern "C" fn ps_hide(wid : Int) -> Unit = "ps_hide"

///|
/// Window `wid` about to be closed by the app (its close let through, not told back as a close asked for).
extern "C" fn ps_let_close(wid : Int) -> Unit = "ps_let_close"

///|
/// One of PinShot's windows beside the overlay closed (a pin, the settings).
fn close_window(wid : Int) -> Unit {
  ps_let_close(wid)
  @ui.window_close_here(wid)
}

///|
/// Window `wid`, `w` by `h` points, in the middle of the monitor the pointer is on, shown and in front.
extern "C" fn ps_center(wid : Int, w : Int, h : Int) -> Unit = "ps_center"

///|
/// Window `wid` kept out of sight while it is still drawn (1), or seen (0).
extern "C" fn ps_cloak(wid : Int, on : Int) -> Unit = "ps_cloak"

///|
/// Window `wid` over the others or among them; `front`: brought before them all now.
extern "C" fn ps_topmost(wid : Int, on : Int, front : Int) -> Unit = "ps_topmost"

///|
/// Window `wid` seen through: 255 not at all.
extern "C" fn ps_opacity(wid : Int, alpha : Int) -> Unit = "ps_opacity"

///|
/// Where window `wid` is: "x,y,w,h,dpi".
extern "C" fn ps_window_rect(wid : Int) -> Bytes = "ps_window_rect"

///|
/// Whether Shift is held now (1).
extern "C" fn ps_shift_down() -> Int = "ps_shift_down"

///|
/// The pointer on the screen: "x,y" (pixels).
extern "C" fn ps_pointer() -> Bytes = "ps_pointer"

///|
/// What the GPU was asked to let go of let go now (the renderer's context flushed: D3D frees a texture released only
/// as its context is flushed, which a hidden window's frames never do).
extern "C" fn ps_gpu_flush() -> Unit = "ps_gpu_flush"

///|
/// "ws,private": the run's memory, in bytes.
extern "C" fn ps_memory() -> Bytes = "ps_memory"

///|
extern "C" fn ps_now_ms() -> Double = "ps_now_ms"

///|
/// The folder of the settings (made).
extern "C" fn ps_data_dir() -> Bytes = "ps_data_dir"

///|
/// The pictures' folder for PinShot (not made).
extern "C" fn ps_pictures_dir() -> Bytes = "ps_pictures_dir"

///|
#borrow(path)
extern "C" fn ps_read_file(path : Bytes) -> Bytes = "ps_read_file"

///|
/// `data` written to `path` whole (its folder made): 1 when it is there.
#borrow(path, data)
extern "C" fn ps_write_file(path : Bytes, data : Bytes) -> Int = "ps_write_file"

///|
/// The system's save dialog (owned by window `wid`): the path chosen, "" none.
#borrow(dir, name)
extern "C" fn ps_save_dialog(wid : Int, dir : Bytes, name : Bytes) -> Bytes = "ps_save_dialog"

///|
/// A folder, or a file in its folder, shown.
#borrow(path)
extern "C" fn ps_reveal(path : Bytes) -> Unit = "ps_reveal"

///|
/// The time now as a file's name says it: "20261117-083015".
extern "C" fn ps_stamp() -> Bytes = "ps_stamp"

///|
extern "C" fn ps_autostart() -> Int = "ps_autostart"

///|
extern "C" fn ps_set_autostart(on : Int) -> Int = "ps_set_autostart"

///|
/// A menu at the pointer over window `wid`: "key\twords\tflags" lines (c checked, g greyed), "-" a separator. The key
/// chosen, "" none.
#borrow(lines)
extern "C" fn ps_popup_menu(wid : Int, lines : Bytes) -> Bytes = "ps_popup_menu"

///|
/// The clipboard's picture as a file's bytes (PNG, or a BMP of its bitmap); empty: none.
extern "C" fn ps_clipboard_image() -> Bytes = "ps_clipboard_image"

///|
/// A comma-separated line's numbers.
fn numbers_of(s : String) -> Array[Double] {
  let out : Array[Double] = []
  for part in s.split(",") {
    let t = part.trim()
    out.push(@string.parse_double(t) catch { _ => 0.0 })
  }
  out
}

///|
/// `s` read as JSON (None: it is not).
fn json_of(s : String) -> Json? {
  try Some(@json.parse(s)) catch {
    _ => None
  }
}
