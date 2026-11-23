// PinShot: a screenshot taken and pinned, as PixPin does it, on mbui (still.fail's way: the UI and what it does in
// MoonBit, written once; what is the system's a thin native side, platform_win.c). One run per person, kept in the
// notification area: its shortcut (Ctrl+Alt+A, as PixPin is set here) or its icon freezes the screen into the overlay (window 0, made as the run starts
// and kept hidden between captures), and each pin is a window of the same run beside it.
//
//   pinshot.exe            the run (started again: the one running takes the screen, as its shortcut; from Downloads/TEMP: installs itself)
//   pinshot.exe --install  installs to %LOCALAPPDATA%\Programs\PinShot, adds Start menu & Settings > Apps entry
//   pinshot.exe --uninstall removes the installed copy, shortcuts, autostart and Settings > Apps entry
//   pinshot.exe --portable runs in place without self-installing
//   pinshot.exe --settings the settings opened (in the one running, or in this one as it starts)
//   pinshot.exe --quit     the one running ended
//   pinshot.exe --bench    the screen taken 10 times and the windows listed, timed; no window
//   pinshot.exe --updated  the run, started by an update in place (update.mbt): it says so
//   pinshot.exe --installed the run, started by a fresh self-install (install_win.c): it says so
//   pinshot.exe --start    the run, started again by an update that did not go through; with --updated/--installed, nothing where one is running already
//   pinshot.exe --ocr <f>  the words in picture file f read and printed; no window

///|
fn main {
  if handle_install_cli() {
    return
  }
  let args = text_of(ps_args()).split("\n").map(fn(s) { s.to_owned() }).collect()
  if args.length() > 0 && args[0] == "--bench" {
    bench()
    ps_quit()
    return
  }
  if args.length() > 1 && args[0] == "--ocr" {
    println(text_of(ps_ocr_now(ps_read_file(cstr(args[1])))))
    ps_quit()
    return
  }
  let again = if args.length() > 0 && args[0] == "--settings" {
    1
  } else if args.length() > 0 && args[0] == "--quit" {
    2
  } else if args.length() > 0 && (args[0] == "--updated" || args[0] == "--installed" || args[0] == "--start") {
    // (the one running, if it is still here, takes nothing from it: no capture)
    3
  } else {
    0
  }
  if ps_start(again) == 0 || again == 2 {
    return
  }
  load_settings()
  let updated = args.length() > 0 && args[0] == "--updated"
  let installed = args.length() > 0 && args[0] == "--installed"
  log("started \{app_version}: icon \{if ps_tray_on() == 1 { "shown" } else { "not shown" }}")
  @ui.on_message_said("ps", fn(json, bytes) {
    told(json, bytes)
    true
  })
  @ui.set_window_tree(fn(wid, what) {
    let build = if what == "settings" {
      settings_window
    } else if what == "welcome" {
      welcome_window
    } else if what == "toast" {
      toast_window
    } else if what == "long" {
      long_window
    } else if what == "rec" {
      rec_window
    } else {
      pin_window(wid, what)
    }
    fn(root) {
      // Every child window has its own window-kept tree theme; apply app_theme (tabular digits) here too.
      @ui.set_tree_theme(app_theme)
      build(root)
    }
  })
  @ui.when_window_closed(fn(wid) {
    if wid == settings_wid.val {
      settings_wid.val = 0
      // (a shortcut asked for and the settings closed: nothing taken, the shortcuts as they were)
      if recording.untracked() != 0 {
        stop_recording()
        apply_keys()
      }
      trim_soon()
    }
    if wid == welcome_wid.val {
      welcome_wid.val = 0
      trim_soon()
    }
    if wid == toast_wid.val {
      toast_wid.val = 0
    }
    if wid == long_wid.val {
      long_gone()
    }
    if wid == rec_wid.val {
      rec_gone()
    }
    pin_gone(wid)
  })
  apply_keys()
  start_updates(updated, installed~)
  // (the overlay made out of sight: it shows only as a capture opens)
  @hostapi.window_hold()
  @hostapi.window_setup(100.0, 100.0, 320.0, 200.0)
  if again == 1 {
    started_with_settings.val = true
  } else if installed || (@ui.env("PINSHOT_TEST") != "" && @ui.env("PINSHOT_TEST_WELCOME") != "") {
    started_with_welcome.val = true
  }
  @ui.run_legacy_ctx("PinShot", fn(c) {
    c.set_clear(0x000000L)
    // (said each frame: a window's tree let go lets go of what was said)
    @ui.set_tree_theme(app_theme)
    overlay_first_frame()
  }, tree=overlay_window)
}

///|
/// What the native side told (a shortcut, the icon, its menu, a window's close, an update's fetch, an OCR reading;
/// `bytes` what a fetch or reading got).
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
      prepare_capture(
        n("x").to_int(),
        n("y").to_int(),
        n("w").to_int(),
        n("h").to_int(),
        n("dpi"),
        wx=n("wx").to_int(),
        wy=n("wy").to_int(),
        ww=n("ww").to_int(),
        wh=n("wh").to_int(),
      )
    }
    "capture" =>
      if capturing.untracked() {
        capture_taken()
      } else {
        // (taken after the capture was called off, as GDI's may be: its pixels let go now, not kept till the next)
        ps_capture_release()
      }
    "capture-failed" => toast(tr("截图失败，请重试。"))
    "pin-clipboard" => pin_clipboard()
    "ocr" => ocr_told(o, bytes)
    "long" => {
      let n = fn(k : String) {
        match o.get(k) {
          Some(Number(v, ..)) => v.to_int()
          _ => 0
        }
      }
      long_told(
        n("h"),
        n("lost") != 0,
        n("full") != 0,
        n("paused") != 0,
        n("pics"),
        n("dir"),
        n("at"),
        n("top"),
      )
    }
    "rec" => {
      let n = fn(k : String) {
        match o.get(k) {
          Some(Number(v, ..)) => v
          _ => 0.0
        }
      }
      let s = fn(k : String) {
        match o.get(k) {
          Some(String(v)) => v
          _ => ""
        }
      }
      rec_told(
        s("state"),
        n("ms").to_int(),
        n("frames").to_int(),
        n("bytes"),
        n("orig"),
        n("pct").to_int(),
        n("audio").to_int(),
        s("codec"),
        s("path"),
        s("err"),
      )
    }
    "rec-av1" =>
      match o.get("on") {
        Some(Number(v, ..)) => rec_av1_told(v.to_int())
        _ => ()
      }
    "rec-rect" => {
      let n = fn(k : String) {
        match o.get(k) {
          Some(Number(v, ..)) => v.to_int()
          _ => 0
        }
      }
      rec_rect_told(n("x"), n("y"), n("w"), n("h"))
    }
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
    "key-pressed" => {
      let n = fn(k : String) {
        match o.get(k) {
          Some(Number(v, ..)) => v.to_int()
          _ => 0
        }
      }
      let how = match o.get("how") {
        Some(String(h)) => h
        _ => "cancel"
      }
      key_pressed(how, n("mods"), n("vk"))
    }
    "fetching" | "fetched" | "setup-ended" => update_told(what, o, bytes)
    "update-tick" => update_tick()
    "close" =>
      match o.get("wid") {
        Some(Number(w, ..)) => {
          let wid = w.to_int()
          if wid == 0 {
            close_capture()
          } else if wid == settings_wid.val {
            close_window(wid)
          } else if wid == long_wid.val {
            long_close()
          } else if wid == rec_wid.val {
            rec_cancel()
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
        Some(String("check-update")) => {
          open_settings(tab=3)
          check_update(true)
        }
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
  ps_capture_now() |> ignore
  let t1 = ps_now_ms()
  let mut n = 0
  for _ in 0..<10 {
    n = parse_windows(text_of(ps_windows())).length()
  }
  let wins = (ps_now_ms() - t1) / 10.0
  println("bench: screen \{text_of(ps_capture_info())}")
  println("bench: take+hand over (ms): " + times.map(num).join(", ").to_string())
  println("bench: windows listed: \{n} in \{num(wins)} ms")
  println("bench: memory ws,private: \{text_of(ps_memory())}")
}

///|
/// Whether the run was started to open its settings (they open once its window is there).
let started_with_settings : Ref[Bool] = Ref(false)

///|
/// Whether the run was just installed interactively (opens the minimal installed welcome card once its window is there).
let started_with_welcome : Ref[Bool] = Ref(false)

///|
/// The theme every window's words are in: dark, as PinShot is, and digits all one width (the user, 2026-11-17: 「有的数字需要用等宽模式」:
/// a number that changes where it stands, the magnifier's place and colour, a size, a zoom, keeps its width).
let app_theme : () -> @ui.Theme = fn() { theme_kept }

///|
let theme_kept : @ui.Theme = { ..@ui.Theme::dark(), tabular: true }

///|
/// PinShot's version: the settings' About, what updates compare with latest.json (update.mbt), and what publish.ps1
/// reads. Raised with each release.
let app_version : String = "1.0.26"
