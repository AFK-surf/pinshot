// PinShot entry point:
//   pinshot.exe                 -> resident tray + global hotkeys (Ctrl+Shift+A, F1)
//   pinshot.exe --capture       -> immediate frozen capture overlay (exits after finish)
//   pinshot.exe --pin <file> <x> <y> <w> <h> -> floating Pin-to-screen window

///|
fn parse_args() -> Array[String] {
  let raw = @utf8.decode_lossy(ps_args_str()[:])
  let out : Array[String] = []
  for line in raw.split("\n") {
    let s = line.to_owned().trim().to_owned()
    if s != "" {
      out.push(s)
    }
  }
  out
}

///|
fn now_ms(root : @view.View) -> Double {
  root.cause_at()
}

///|
fn resident_poll(root : @view.View) -> Unit {
  let act = ps_poll_action()
  if act == 1 && !overlay_visible.untracked() {
    if start_capture() {
      overlay_visible.set(true)
      ps_setup_popup(mon_x.val, mon_y.val, mon_w.val, mon_h.val, 1) |> ignore
    }
  } else if act == 2 {
    let clip = ps_clipboard_png()
    if clip.length() > 8 {
      let (iw, ih) = match @pixels.image_size(clip) {
        Some((w, h)) => (w, h)
        None => (400, 300)
      }
      ps_launch_pin(clip, 160, 120, @cmp.maximum(120, iw), @cmp.maximum(90, ih)) |> ignore
    }
  } else if act == 3 {
    @ui.window_close_here(0)
    return
  }
  root.at_moment(now_ms(root) + 50.0, fn() { resident_poll(root) }, later=true) |> ignore
}

///|
fn main {
  let args = parse_args()
  if args.length() >= 6 && args[0] == "--pin" {
    let path = args[1]
    pin_path.val = path
    pin_x.val = parse_int_or(args[2], 100)
    pin_y.val = parse_int_or(args[3], 100)
    pin_base_w.val = @cmp.maximum(48, parse_int_or(args[4], 400))
    pin_base_h.val = @cmp.maximum(48, parse_int_or(args[5], 300))
    let bytes = ps_read_file(cstr(path))
    pin_png_bytes.val = bytes
    if bytes.length() > 0 {
      @ui.add_image("pin-img", bytes)
    }
    @hostapi.window_setup(48.0, 48.0, pin_base_w.val.to_double(), pin_base_h.val.to_double(), inset=true)
    let pin_setup_done = Ref(false)
    @ui.run("PinShot Pin", fn(c) {
      c.set_clear(0x18181BL)
      if !pin_setup_done.val {
        if ps_setup_popup(pin_x.val, pin_y.val, pin_base_w.val, pin_base_h.val, 1) == 1 {
          pin_setup_done.val = true
        }
      }
    }, tree=fn(root) {
      pin_window_view(root)
    })
    return
  }

  if args.length() >= 1 && args[0] == "--capture" {
    if !start_capture() {
      return
    }
    @hostapi.window_setup(100.0, 100.0, win_w.untracked(), win_h.untracked(), inset=true)
    let cap_setup_done = Ref(false)
    @ui.run("PinShot", fn(c) {
      c.set_clear(0x000000L)
      if !cap_setup_done.val {
        overlay_visible.set(true)
        if ps_setup_popup(mon_x.val, mon_y.val, mon_w.val, mon_h.val, 1) == 1 {
          cap_setup_done.val = true
        }
      }
    }, tree=fn(root) {
      capture_overlay_view(root, true)
    })
    return
  }

  // Resident tray + global hotkey mode
  ps_tray_start() |> ignore
  @hostapi.window_setup(100.0, 100.0, 400.0, 300.0, inset=true)
  let tray_setup_done = Ref(false)
  @ui.run("PinShot", fn(c) {
    c.set_clear(0x000000L)
    if !tray_setup_done.val {
      if ps_setup_popup(0, 0, 400, 300, 1) == 1 {
        ps_hide_window()
        tray_setup_done.val = true
      }
    }
  }, tree=fn(root) {
    capture_overlay_view(root, false)
    resident_poll(root)
  })
}
