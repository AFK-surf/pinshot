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
fn bench_ms(t0 : Int64, t1 : Int64) -> String {
  let us = t1 - t0
  let ms = us.to_double() / 1000.0
  let whole = ms.to_int()
  let frac = ((ms - whole.to_double()) * 100.0).round().to_int()
  let fs = if frac < 10 { "0\{frac}" } else { "\{frac}" }
  "\{whole}.\{fs} ms"
}

///|
fn run_bench() -> Unit {
  // 1. Screen capture benchmark (5 runs)
  let t0 = ps_now_us()
  let mut cap_ok = 0
  for i = 0; i < 5; i = i + 1 {
    if ps_capture_screen() == 1 {
      cap_ok += 1
    }
  }
  let t1 = ps_now_us()
  let info = @utf8.decode_lossy(ps_capture_info()[:])
  let bmp = ps_capture_bmp()
  println("CAPTURE_INFO=\{info} bmp_bytes=\{bmp.length()} ok=\{cap_ok}/5 total=\{bench_ms(t0, t1)} avg=\{bench_ms(0L, (t1 - t0) / 5L)}")

  // Parse monitor info for export benchmarks
  let parts = info.split(",").map(fn(s) { s.to_owned() }).to_array()
  if parts.length() >= 5 {
    mon_x.val = parse_int_or(parts[0], 0)
    mon_y.val = parse_int_or(parts[1], 0)
    mon_w.val = parse_int_or(parts[2], 1920)
    mon_h.val = parse_int_or(parts[3], 1080)
    mon_scale.val = @cmp.maximum(1.0, parse_double_or(parts[4], 1.0))
    win_w.set(mon_w.val.to_double() / mon_scale.val)
    win_h.set(mon_h.val.to_double() / mon_scale.val)
    frozen_bmp.val = bmp
  }

  // 2. Window enumeration benchmark (10 runs)
  let ew0 = ps_now_us()
  let mut wins_len = 0
  for i = 0; i < 10; i = i + 1 {
    wins_len = ps_enum_windows().length()
  }
  let ew1 = ps_now_us()
  println("ENUM_WINDOWS bytes=\{wins_len} avg=\{bench_ms(0L, (ew1 - ew0) / 10L)}")

  // 3. Export PNG benchmarks
  let s = mon_scale.val
  let cases : Array[(String, Double, Double, Bool)] = [
    ("800x600_clean", 800.0 / s, 600.0 / s, false),
    ("800x600_annotated", 800.0 / s, 600.0 / s, true),
    ("1920x1080_clean", 1920.0 / s, 1080.0 / s, false),
    ("3840x2160_full4k", win_w.untracked(), win_h.untracked(), false),
  ]
  for c in cases {
    let (name, lw, lh, with_ann) = c
    sel.set(Some({ x: 0.0, y: 0.0, w: lw, h: lh }))
    if with_ann {
      annotations.set([
        { kind: Rect, x0: 40.0, y0: 40.0, x1: 220.0, y1: 140.0, color: 0xEF4444FFL, stroke: 3.0, step_num: 0, pts: [] },
        { kind: Arrow, x0: 60.0, y0: 180.0, x1: 280.0, y1: 220.0, color: 0x3B82F6FFL, stroke: 3.0, step_num: 0, pts: [] },
        { kind: Step, x0: 300.0, y0: 80.0, x1: 300.0, y1: 80.0, color: 0x10B981FFL, stroke: 3.0, step_num: 1, pts: [] },
        { kind: Mosaic, x0: 100.0, y0: 100.0, x1: 260.0, y1: 200.0, color: 0xFFFFFFFFL, stroke: 3.0, step_num: 0, pts: [] },
      ])
    } else {
      annotations.set([])
    }
    let e0 = ps_now_us()
    let png = export_selection_png()
    let e1 = ps_now_us()
    let out_len = match png {
      Some(b) => b.length()
      None => 0
    }
    println("EXPORT_\{name} png_bytes=\{out_len} time=\{bench_ms(e0, e1)}")
  }

  // 4. Clipboard PNG read benchmark (5 runs)
  let c0 = ps_now_us()
  let mut cb_len = 0
  for i = 0; i < 5; i = i + 1 {
    cb_len = ps_clipboard_png().length()
  }
  let c1 = ps_now_us()
  println("CLIPBOARD_READ bytes=\{cb_len} avg=\{bench_ms(0L, (c1 - c0) / 5L)}")
}

///|
fn main {
  let args = parse_args()
  if args.length() >= 1 && args[0] == "--bench" {
    run_bench()
    return
  }
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
