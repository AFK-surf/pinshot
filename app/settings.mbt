// Persistent user settings (`%APPDATA%\PinShot\settings.ini`) and `--settings` UI.

///|
let cfg_hotkey_capture : @signals.Signal[Int] = @signals.signal(0) // 0=Ctrl+Shift+A+F1, 1=Ctrl+Shift+A, 2=F1, 3=Ctrl+Alt+A

///|
let cfg_hotkey_pin_front : @signals.Signal[Int] = @signals.signal(0) // 0=Ctrl+Shift+P, 1=F2, 2=Off

///|
let cfg_autostart : @signals.Signal[Bool] = @signals.signal(false)

///|
let cfg_pin_topmost : @signals.Signal[Bool] = @signals.signal(true)

///|
let cfg_pin_opacity : @signals.Signal[Int] = @signals.signal(255)

///|
let cfg_png_compress : @signals.Signal[Bool] = @signals.signal(true)

///|
let cfg_auto_save : @signals.Signal[Bool] = @signals.signal(false)

///|
let cfg_save_dir : @signals.Signal[String] = @signals.signal("")

///|
let cfg_saved_hint : @signals.Signal[Bool] = @signals.signal(false)

///|
fn load_settings() -> Unit {
  let def_dir = @utf8.decode_lossy(ps_default_save_dir()[:])
  cfg_save_dir.set(def_dir)
  cfg_autostart.set(ps_get_autostart() == 1)
  let raw = @utf8.decode_lossy(ps_read_settings()[:])
  if raw == "" {
    return
  }
  for line in raw.split("\n") {
    let s = line.to_owned().trim().to_owned()
    if s == "" {
      continue
    }
    match s.find("=") {
      Some(eq) => {
        let k = s[:eq].to_owned()
        let v = s[eq + 1:].to_owned()
        if k == "hotkey_capture" {
          cfg_hotkey_capture.set(parse_int_or(v, 0))
        } else if k == "hotkey_pin_front" {
          cfg_hotkey_pin_front.set(parse_int_or(v, 0))
        } else if k == "pin_topmost" {
          cfg_pin_topmost.set(parse_int_or(v, 1) != 0)
        } else if k == "pin_opacity" {
          cfg_pin_opacity.set(@cmp.maximum(60, @cmp.minimum(255, parse_int_or(v, 255))))
        } else if k == "png_compress" {
          cfg_png_compress.set(parse_int_or(v, 1) != 0)
        } else if k == "auto_save" {
          cfg_auto_save.set(parse_int_or(v, 0) != 0)
        } else if k == "save_dir" && v != "" {
          cfg_save_dir.set(v)
        }
      }
      None => ()
    }
  }
}

///|
fn save_settings() -> Unit {
  let b1 = if cfg_pin_topmost.untracked() { 1 } else { 0 }
  let b2 = if cfg_png_compress.untracked() { 1 } else { 0 }
  let b3 = if cfg_auto_save.untracked() { 1 } else { 0 }
  let b4 = if cfg_autostart.untracked() { 1 } else { 0 }
  let text =
    "hotkey_capture=\{cfg_hotkey_capture.untracked()}\n" +
    "hotkey_pin_front=\{cfg_hotkey_pin_front.untracked()}\n" +
    "autostart=\{b4}\n" +
    "pin_topmost=\{b1}\n" +
    "pin_opacity=\{cfg_pin_opacity.untracked()}\n" +
    "png_compress=\{b2}\n" +
    "auto_save=\{b3}\n" +
    "save_dir=\{cfg_save_dir.untracked()}\n"
  ps_write_settings(@utf8.encode(text)) |> ignore
  ps_set_autostart(b4) |> ignore
  ps_notify_reload_settings()
  cfg_saved_hint.set(true)
}

///|
fn seg_btn(parent : @view.View, label : String, active : () -> Bool, act : () -> Unit) -> Unit {
  parent.box(fn(b) {
    b
    .padding(Is((10.0, 5.0, 10.0, 5.0)))
    .radius(Is(6.0))
    .presses(Is(true))
    .cursor(Is(Some(Arrow)))
    .ground(By(fn() { if active() { 0x3B82F6FFL } else { 0x27272AFFL } }))
    .edge(By(fn() { if active() { (1.0, 0x60A5FAFFL) } else { (1.0, 0x3F3F46FFL) } }))
    .on_press(fn() { act() })
    |> ignore
    b.box(fn(w) {
      w
      .words(Is(label), look={ ..@view.words_plain, size: 12.0, weight: 500 })
      .ink(By(fn() { if active() { 0xFFFFFFFFL } else { 0xD4D4D8FFL } }))
      |> ignore
    }) |> ignore
  }) |> ignore
}

///|
fn setting_row(parent : @view.View, title : String, build : (@view.View) -> Unit) -> Unit {
  parent.box(fn(row) {
    row
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .padding(Is((0.0, 6.0, 0.0, 6.0)))
    .gap(Is(12.0))
    |> ignore
    row.box(fn(lbl) {
      lbl.width(Is(Some(118.0))) |> ignore
      lbl.box(fn(w) {
        w.words(Is(title), ink=0xE4E4E7FFL, look={ ..@view.words_plain, size: 13.0, weight: 500 }) |> ignore
      }) |> ignore
    }) |> ignore
    row.box(fn(ctrl) {
      ctrl.row(Is(true)).gap(Is(6.0)).grow(Is(1.0)) |> ignore
      build(ctrl)
    }) |> ignore
  }) |> ignore
}

///|
fn settings_window_view(root : @view.View) -> Unit {
  let bindings = @view.Keymap::new([
    @view.Binding::{ keys: [@view.Stroke::{ code: 0x1B, mods: 0 }], action: "close", when: Always },
  ])
  root.keymap(Is(bindings)) |> ignore
  root.on_action("close", fn(_) {
    @ui.window_close_here(0)
    true
  }) |> ignore

  root.box(fn(panel) {
    panel
    .grow(Is(1.0))
    .padding(Is((20.0, 18.0, 20.0, 18.0)))
    .ground(Is(0x141417FFL))
    .gap(Is(6.0))
    |> ignore

    // Header (draggable)
    panel.box(fn(hdr) {
      hdr.row(Is(true)).lines_up(Is(Some(Middle))).presses(Is(true)).moves_window(Is(true)).padding(Is((0.0, 0.0, 0.0, 10.0))) |> ignore
      hdr.box(fn(t) {
        t.grow(Is(1.0)) |> ignore
        t.box(fn(w) {
          w.words(Is("PinShot 设置"), ink=0xFAFAFAFFL, look={ ..@view.words_plain, size: 16.0, weight: 600 }) |> ignore
        }) |> ignore
      }) |> ignore
      tb_btn(hdr, "关闭", fn() { false }, fn() { @ui.window_close_here(0) })
    }) |> ignore

    // Capture hotkey
    setting_row(panel, "截屏快捷键", fn(c) {
      seg_btn(c, "Ctrl+Shift+A / F1", fn() { cfg_hotkey_capture.get() == 0 }, fn() { cfg_hotkey_capture.set(0) })
      seg_btn(c, "Ctrl+Shift+A", fn() { cfg_hotkey_capture.get() == 1 }, fn() { cfg_hotkey_capture.set(1) })
      seg_btn(c, "F1", fn() { cfg_hotkey_capture.get() == 2 }, fn() { cfg_hotkey_capture.set(2) })
      seg_btn(c, "Ctrl+Alt+A", fn() { cfg_hotkey_capture.get() == 3 }, fn() { cfg_hotkey_capture.set(3) })
    })

    // Pin to front hotkey
    setting_row(panel, "贴图置前快捷键", fn(c) {
      seg_btn(c, "Ctrl+Shift+P", fn() { cfg_hotkey_pin_front.get() == 0 }, fn() { cfg_hotkey_pin_front.set(0) })
      seg_btn(c, "F2", fn() { cfg_hotkey_pin_front.get() == 1 }, fn() { cfg_hotkey_pin_front.set(1) })
      seg_btn(c, "关闭", fn() { cfg_hotkey_pin_front.get() == 2 }, fn() { cfg_hotkey_pin_front.set(2) })
    })

    // Default pin topmost
    setting_row(panel, "贴图默认置顶", fn(c) {
      seg_btn(c, "开启（推荐）", fn() { cfg_pin_topmost.get() }, fn() { cfg_pin_topmost.set(true) })
      seg_btn(c, "关闭", fn() { !cfg_pin_topmost.get() }, fn() { cfg_pin_topmost.set(false) })
    })

    // Default pin opacity
    setting_row(panel, "贴图默认透明度", fn(c) {
      seg_btn(c, "100%", fn() { cfg_pin_opacity.get() == 255 }, fn() { cfg_pin_opacity.set(255) })
      seg_btn(c, "90%", fn() { cfg_pin_opacity.get() == 230 }, fn() { cfg_pin_opacity.set(230) })
      seg_btn(c, "78%", fn() { cfg_pin_opacity.get() == 200 }, fn() { cfg_pin_opacity.set(200) })
    })

    // PNG compression
    setting_row(panel, "PNG 导出压缩", fn(c) {
      seg_btn(c, "WIC 压缩（小体积）", fn() { cfg_png_compress.get() }, fn() { cfg_png_compress.set(true) })
      seg_btn(c, "无压缩（极速）", fn() { !cfg_png_compress.get() }, fn() { cfg_png_compress.set(false) })
    })

    // Auto save & autostart
    setting_row(panel, "复制时自动保存", fn(c) {
      seg_btn(c, "关闭", fn() { !cfg_auto_save.get() }, fn() { cfg_auto_save.set(false) })
      seg_btn(c, "开启", fn() { cfg_auto_save.get() }, fn() { cfg_auto_save.set(true) })
    })

    setting_row(panel, "开机自启", fn(c) {
      seg_btn(c, "关闭", fn() { !cfg_autostart.get() }, fn() { cfg_autostart.set(false) })
      seg_btn(c, "开启", fn() { cfg_autostart.get() }, fn() { cfg_autostart.set(true) })
    })

    // Save dir hint
    setting_row(panel, "自动保存目录", fn(c) {
      c.box(fn(w) {
        w.words(By(fn() { cfg_save_dir.get() }), ink=0xA1A1AAFFL, look={ ..@view.words_plain, size: 11.5 }) |> ignore
      }) |> ignore
    })

    // Footer save button
    panel.box(fn(ftr) {
      ftr.row(Is(true)).lines_up(Is(Some(Middle))).padding(Is((12.0, 0.0, 0.0, 0.0))).gap(Is(10.0)) |> ignore
      ftr.box(fn(sp) {
        sp.grow(Is(1.0)) |> ignore
        sp.box(fn(w) {
          w.words(By(fn() { if cfg_saved_hint.get() { "已保存并立即生效" } else { "" } }),
                  ink=0x10B981FFL, look={ ..@view.words_plain, size: 12.0 }) |> ignore
        }) |> ignore
      }) |> ignore
      tb_btn(ftr, "保存并应用", fn() { false }, save_settings, primary=true)
    }) |> ignore
  }) |> ignore
}
