// PinShot: a screenshot taken and pinned, as PixPin does it, on mbui (still.fail's way: the UI and what it does in
// MoonBit, written once; what is the system's a thin native side, platform_win.c). One run per person, kept in the
// notification area: its shortcut (Ctrl+Alt+A, as PixPin is set here) or its icon freezes the screen into the overlay (window 0, made as the run starts
// and kept hidden between captures), and each pin is a window of the same run beside it.
//
//   pinshot.exe            the run (started again: the one running takes the screen, as its shortcut)
//   pinshot.exe --settings the settings opened (in the one running, or in this one as it starts)
//   pinshot.exe --quit     the one running ended
//   pinshot.exe --bench    the screen taken 10 times and the windows listed, timed; no window
//   pinshot.exe --ocr <f> [lang]  the words in picture file f read (in lang: zh, en, ja, ko...; * every language's
//                          reading, scored) and printed; no window

///|
fn main {
  let args = text_of(ps_args()).split("\n").map(fn(s) { s.to_owned() }).collect()
  if args.length() > 0 && args[0] == "--bench" {
    bench()
    return
  }
  if args.length() > 1 && args[0] == "--ocr" {
    let want = if args.length() > 2 { args[2] } else { "" }
    println(text_of(ps_ocr_now(ps_read_file(cstr(args[1])), @utf8.encode(want))))
    return
  }
  let again = if args.length() > 0 && args[0] == "--settings" {
    1
  } else if args.length() > 0 && args[0] == "--quit" {
    2
  } else {
    0
  }
  if ps_start(again) == 0 || again == 2 {
    return
  }
  load_settings()
  log("started: icon \{if ps_tray_on() == 1 { "shown" } else { "not shown" }}")
  @ui.on_message_said("ps", fn(json, bytes) {
    told(json, bytes)
    true
  })
  @ui.set_window_tree(fn(wid, what) {
    if what == "settings" {
      settings_window
    } else if what == "toast" {
      toast_window
    } else if what == "ocr" {
      ocr_window
    } else {
      pin_window(wid, what)
    }
  })
  @ui.when_window_closed(fn(wid) {
    if wid == settings_wid.val {
      settings_wid.val = 0
    }
    if wid == toast_wid.val {
      toast_wid.val = 0
    }
    if wid == ocr_wid.val {
      ocr_wid.val = 0
    }
    pin_gone(wid)
  })
  apply_keys()
  // (the overlay made out of sight: it shows only as a capture opens)
  @hostapi.window_hold()
  @hostapi.window_setup(100.0, 100.0, 320.0, 200.0)
  if again == 1 {
    started_with_settings.val = true
  }
  @ui.run("PinShot", fn(c) {
    c.set_clear(0x000000L)
    // (said each frame: a window's tree let go lets go of what was said)
    @ui.set_tree_theme(app_theme)
    overlay_first_frame()
  }, tree=overlay_window)
}

///|
/// What the native side told (a shortcut, the icon, its menu, a window's close).
fn told(json : String, bytes : Bytes?) -> Unit {
  guard json_of(json) is Some(Json::Object(o)) else { return }
  let what = match o.get("do") {
    Some(String(s)) => s
    _ => ""
  }
  match what {
    "prepare" => {
      let n = fn(k : String) {
        match o.get(k) {
          Some(Number(v, ..)) => v
          _ => 0.0
        }
      }
      asked_at.val = n("t")
      prepare_capture(n("x").to_int(), n("y").to_int(), n("w").to_int(), n("h").to_int(), n("dpi"))
    }
    "capture" => if capturing.untracked() { capture_taken() }
    "pin-clipboard" => pin_clipboard()
    "ocr" => ocr_told(o, bytes)
    "tick" =>
      match o.get("wid") {
        Some(Number(w, ..)) => pin_tick(w.to_int())
        _ => ()
      }
    "active" =>
      match (o.get("wid"), o.get("on")) {
        (Some(Number(w, ..)), Some(Number(on, ..))) => pin_active(w.to_int(), on != 0.0)
        _ => ()
      }
    "pins" => pins_toggle()
    "close" =>
      match o.get("wid") {
        Some(Number(w, ..)) => {
          let wid = w.to_int()
          if wid == 0 {
            close_capture()
          } else if wid == settings_wid.val || wid == ocr_wid.val {
            close_window(wid)
          } else {
            close_pin(wid)
          }
        }
        _ => ()
      }
    "menu" =>
      match o.get("item") {
        Some(String("capture")) => ps_capture_ask()
        Some(String("pin-clip")) => pin_clipboard()
        Some(String("pins")) => pins_toggle()
        Some(String("settings")) => open_settings()
        Some(String("folder")) => ps_reveal(cstr(settings.untracked().save_dir))
        Some(String("quit")) => ps_quit()
        _ => ()
      }
    _ => ()
  }
}

///|
/// The screen taken 10 times and the windows listed 10 times, timed; the run's memory.
fn bench() -> Unit {
  let times : Array[Double] = []
  for _ in 0..<10 {
    let t0 = ps_now_ms()
    ps_capture_now() |> ignore
    let b = ps_capture_take()
    times.push(ps_now_ms() - t0)
    println("bench: \{text_of(ps_capture_info())}")
    ignore(b)
    ps_capture_release()
  }
  let t1 = ps_now_ms()
  let mut n = 0
  for _ in 0..<10 {
    n = parse_windows(text_of(ps_windows())).length()
  }
  let wins = (ps_now_ms() - t1) / 10.0
  ps_capture_now() |> ignore
  println("bench: screen \{text_of(ps_capture_info())}")
  println("bench: take+hand over (ms): " + times.map(num).join(", ").to_string())
  println("bench: windows listed: \{n} in \{num(wins)} ms")
  println("bench: memory ws,private: \{text_of(ps_memory())}")
}

///|
/// Whether the run was started to open its settings (they open once its window is there).
let started_with_settings : Ref[Bool] = Ref(false)

///|
/// The theme every window's words are in: dark, as PinShot is, and digits all one width (the user, 2026-11-17: 「有的数字需要用等宽模式」:
/// a number that changes where it stands, the magnifier's place and colour, a size, a zoom, keeps its width).
let app_theme : () -> @ui.Theme = fn() { theme_kept }

///|
let theme_kept : @ui.Theme = { ..@ui.Theme::dark(), tabular: true }

///|
/// PinShot's version (the settings' About, the Store's package).
let app_version : String = "1.0.0"
