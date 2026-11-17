// The settings (settings.json in %APPDATA%\PinShot) and their window: the shortcuts, how a pin opens, where pictures
// are saved, and whether PinShot starts with Windows. A change is written and in force at once.

///|
#derive(Eq)
struct Settings {
  /// the shortcuts: which of `key_choices` (capture) and `pin_choices` (pin the clipboard)
  capture_key : Int
  pin_key : Int
  /// a pin over the other windows as it opens, and how clear (255 not seen through)
  pin_top : Bool
  pin_alpha : Int
  /// saving: the system's dialog each time (else straight into the folder), the folder, and a copy kept there too
  ask_where : Bool
  save_dir : String
  keep_copies : Bool
  /// a shutter's sound as a capture is copied, saved or pinned
  sound : Bool
}

///|
/// The shortcuts offered: their words, and Windows' modifiers (Alt 1, Ctrl 2, Shift 4) and key. The first of each is
/// what PixPin is set to on the person's machine (the user, 2026-11-17: 「快捷键对齐一下」): Ctrl+Alt+A takes the
/// screen, Ctrl+2 pins the clipboard's picture; the others are PixPin's and Snipaste's defaults.
let key_choices : Array[(String, Int, Int)] = [
  ("Ctrl+Alt+A", 3, 0x41),
  ("Ctrl+1", 2, 0x31),
  ("F1", 0, 0x70),
  ("Ctrl+Shift+A", 6, 0x41),
  ("PrtSc", 0, 0x2C),
]

///|
let pin_choices : Array[(String, Int, Int)] = [
  ("Ctrl+2", 2, 0x32),
  ("F3", 0, 0x72),
  ("F2", 0, 0x71),
  ("不用快捷键", 0, 0),
]

///|
/// Which of `choices` is named `name` (kept by its name: the list's order may change), else the first.
fn choice_named(choices : Array[(String, Int, Int)], name : String) -> Int {
  for i, c in choices {
    if c.0 == name {
      return i
    }
  }
  0
}

///|
fn default_settings() -> Settings {
  {
    capture_key: 0,
    pin_key: 0,
    pin_top: true,
    pin_alpha: 255,
    ask_where: true,
    save_dir: text_of(ps_pictures_dir()),
    keep_copies: false,
    sound: true,
  }
}

///|
let settings : @signals.Signal[Settings] = @signals.signal({
  capture_key: 0,
  pin_key: 0,
  pin_top: true,
  pin_alpha: 255,
  ask_where: true,
  save_dir: "",
  keep_copies: false,
  sound: true,
})

///|
/// Whether each shortcut is PinShot's (another program may hold it).
let capture_key_ok : @signals.Signal[Bool] = @signals.signal(true)

///|
let pin_key_ok : @signals.Signal[Bool] = @signals.signal(true)

///|
let autostart : @signals.Signal[Bool] = @signals.signal(false)

///|
fn settings_path() -> String {
  text_of(ps_data_dir()) + "\\settings.json"
}

///|
fn load_settings() -> Unit {
  let d = default_settings()
  let s = match json_of(text_of(ps_read_file(cstr(settings_path())))) {
    Some(Json::Object(o)) => {
      let num = fn(name : String, dflt : Int) {
        match o.get(name) {
          Some(Number(v, ..)) => v.to_int()
          _ => dflt
        }
      }
      let flag = fn(name : String, dflt : Bool) {
        match o.get(name) {
          Some(True) => true
          Some(False) => false
          _ => dflt
        }
      }
      let text = fn(name : String, dflt : String) {
        match o.get(name) {
          Some(String(v)) if v != "" => v
          _ => dflt
        }
      }
      {
        capture_key: choice_named(key_choices, text("capture_keys", key_choices[0].0)),
        pin_key: choice_named(pin_choices, text("pin_keys", pin_choices[0].0)),
        pin_top: flag("pin_top", d.pin_top),
        pin_alpha: clampi(num("pin_alpha", d.pin_alpha), 25, 255),
        ask_where: flag("ask_where", d.ask_where),
        save_dir: text("save_dir", d.save_dir),
        keep_copies: flag("keep_copies", d.keep_copies),
        sound: flag("sound", d.sound),
      }
    }
    _ => d
  }
  settings.set(s)
  autostart.set(ps_autostart() == 1)
}

///|
fn save_settings() -> Unit {
  let s = settings.untracked()
  let o : Map[String, Json] = Map([])
  o["capture_keys"] = Json::string(key_choices[s.capture_key].0)
  o["pin_keys"] = Json::string(pin_choices[s.pin_key].0)
  o["pin_top"] = Json::boolean(s.pin_top)
  o["pin_alpha"] = Json::number(s.pin_alpha.to_double())
  o["ask_where"] = Json::boolean(s.ask_where)
  o["save_dir"] = Json::string(s.save_dir)
  o["keep_copies"] = Json::boolean(s.keep_copies)
  o["sound"] = Json::boolean(s.sound)
  ps_write_file(cstr(settings_path()), @utf8.encode(Json::object(o).stringify(indent=2))) |> ignore
}

///|
/// The settings changed by `f`, written, and in force.
fn change_settings(f : (Settings) -> Settings) -> Unit {
  let was = settings.untracked()
  let s = f(was)
  if s == was {
    return
  }
  settings.set(s)
  save_settings()
  if s.capture_key != was.capture_key || s.pin_key != was.pin_key {
    apply_keys()
  }
}

///|
/// The shortcuts set as the settings say, and the icon's menu naming them.
fn apply_keys() -> Unit {
  let s = settings.untracked()
  let (cw, cm, cv) = key_choices[s.capture_key]
  let (pw, pm, pv) = pin_choices[s.pin_key]
  capture_key_ok.set(ps_hotkey(1, cm, cv) == 1)
  pin_key_ok.set(ps_hotkey(2, pm, pv) == 1)
  log("keys: capture \{cw} \{if capture_key_ok.untracked() { "ok" } else { "taken by another program" }}, pin \{pw} \{if pin_key_ok.untracked() { "ok" } else { "taken by another program" }}")
  // (a shortcut another program holds said once, as it is found: PixPin started with Windows holds Ctrl+Alt+A)
  if !capture_key_ok.untracked() {
    ps_tray_note(cstr("截图快捷键 \{cw} 被其他程序占用"), cstr("点这里打开 PinShot 设置换一个；或者退出占用它的程序（比如 PixPin）后重新打开 PinShot。"))
  }
  let pin_words = if pv == 0 { "贴图剪贴板中的图片" } else { "贴图剪贴板中的图片\u{8}" + pw }
  let menu = "capture\t截图\u{8}" +
    cw +
    "\npin-clip\t" +
    pin_words +
    "\npins\t显示/隐藏全部贴图\n-\nsettings\t设置…\nfolder\t打开截图文件夹\n-\nquit\t退出 PinShot\n"
  ps_set_menu(@utf8.encode(menu))
}

// ---- the window ----

///|
let settings_wid : Ref[Int] = Ref(0)

///|
fn open_settings() -> Unit {
  if settings_wid.val > 0 && @ui.window_front_here(settings_wid.val) {
    return
  }
  let wid = @ui.window_open_here("settings")
  if wid <= 0 {
    return
  }
  settings_wid.val = wid
  ps_center(wid, 540, 650)
}

///|
let set_ink : Int64 = 0xEDEEF0FFL

///|
let set_muted : Int64 = 0x9EA3ABFFL

///|
let set_ground : Int64 = 0x1B1C1FFFL

///|
let set_card : Int64 = 0x232428FFL

///|
fn settings_window(root : @view.View) -> Unit {
  root.tree.hand_over_presses(false)
  root.box(fn(page) {
    page.over(Is(true)).ground(Is(set_ground)).padding(Is((24.0, 18.0, 24.0, 20.0))).gap(Is(14.0)) |> ignore
    settings_page(page)
  })
  |> ignore
}

///|
fn settings_page(root : @view.View) -> Unit {
  set_words(root, fn() { "PinShot 设置" }, 17.0, set_ink, weight=600)
  set_group(root, "快捷键", fn(g) {
    set_row(g, "截图", fn(r) {
      choice(r, key_choices.map(fn(c) { c.0 }), fn() { settings.get().capture_key }, fn(i) {
        change_settings(fn(s) { { ..s, capture_key: i } })
      })
    }, note=fn() { if capture_key_ok.get() { "" } else { "已被其他程序占用，换一个" } })
    set_row(g, "贴图剪贴板中的图片", fn(r) {
      choice(r, pin_choices.map(fn(c) { c.0 }), fn() { settings.get().pin_key }, fn(i) {
        change_settings(fn(s) { { ..s, pin_key: i } })
      })
    }, note=fn() { if pin_key_ok.get() { "" } else { "已被其他程序占用，换一个" } })
  })
  set_group(root, "贴图", fn(g) {
    set_row(g, "打开时置顶", fn(r) {
      switch(r, fn() { settings.get().pin_top }, fn(on) { change_settings(fn(s) { { ..s, pin_top: on } }) })
    })
    set_row(g, "打开时的不透明度", fn(r) {
      let values = [255, 204, 153]
      choice(r, ["100%", "80%", "60%"], fn() {
        let a = settings.get().pin_alpha
        if a >= 255 {
          0
        } else if a >= 204 {
          1
        } else {
          2
        }
      }, fn(i) { change_settings(fn(s) { { ..s, pin_alpha: values[i] } }) })
    })
  })
  set_group(root, "保存", fn(g) {
    set_row(g, "每次询问保存位置", fn(r) {
      switch(r, fn() { settings.get().ask_where }, fn(on) { change_settings(fn(s) { { ..s, ask_where: on } }) })
    })
    set_row(g, "复制时也保存一份到文件夹", fn(r) {
      switch(r, fn() { settings.get().keep_copies }, fn(on) { change_settings(fn(s) { { ..s, keep_copies: on } }) })
    })
    set_row(g, "文件夹", fn(r) {
      r.box(fn(b) {
        b.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        set_words(b, fn() { settings.get().save_dir }, 12.0, set_muted)
      })
      |> ignore
      small_button(r, "打开", fn() { ps_reveal(cstr(settings.untracked().save_dir)) })
    })
  })
  set_group(root, "通用", fn(g) {
    set_row(g, "复制、保存、贴图时播放快门音效", fn(r) {
      switch(r, fn() { settings.get().sound }, fn(on) {
        change_settings(fn(s) { { ..s, sound: on } })
        if on {
          ps_shutter()
        }
      })
    })
    set_row(g, "开机时启动 PinShot", fn(r) {
      switch(r, fn() { autostart.get() }, fn(on) {
        if ps_set_autostart(if on { 1 } else { 0 }) == 1 {
          autostart.set(on)
        }
      })
    })
  })
}

///|
fn set_words(parent : @view.View, text : () -> String, size : Double, ink : Int64, weight? : Int = 400) -> Unit {
  parent.box(fn(w) {
    w.words(By(text), look={ ..@view.words_plain, size, weight, line: (size * 1.45).round(), wrap: false }).ink(Is(ink)) |> ignore
  })
  |> ignore
}

///|
fn set_group(parent : @view.View, title : String, make : (@view.View) -> Unit) -> Unit {
  parent.box(fn(g) {
    g.gap(Is(6.0)) |> ignore
    set_words(g, fn() { title }, 12.0, set_muted, weight=500)
    g.box(fn(card) {
      card.ground(Is(set_card)).radius(Is(10.0)).edge(Is((1.0, 0xFFFFFF14L))).padding(Is((14.0, 4.0, 14.0, 4.0))) |> ignore
      make(card)
    })
    |> ignore
  })
  |> ignore
}

///|
fn set_row(parent : @view.View, label : String, make : (@view.View) -> Unit, note? : () -> String = fn() { "" }) -> Unit {
  parent.box(fn(row) {
    row.row(Is(true)).min_height(Is(Some(42.0))).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
    row.box(fn(l) {
      l.grow(Is(1.0)).gap(Is(2.0)) |> ignore
      set_words(l, fn() { label }, 13.0, set_ink)
      l.box(fn(n) {
        n
        .laid_nowhere(By(fn() { note() == "" }))
        .words(By(note), look={ ..@view.words_plain, size: 11.5, weight: 400, line: 16.0, wrap: false })
        .ink(Is(0xE5A545FFL))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    make(row)
  })
  |> ignore
}

///|
/// A row of choices, the one in force lit.
fn choice(parent : @view.View, names : Array[String], at : () -> Int, pick : (Int) -> Unit) -> Unit {
  parent.box(fn(seg) {
    seg.row(Is(true)).pad(Is(2.0)).radius(Is(7.0)).ground(Is(0x17181BFFL)).gap(Is(2.0)).shrink(Is(0.0)) |> ignore
    for i, name in names {
      seg.box(fn(b) {
        b
        .height(Is(Some(26.0)))
        .padding(Is((9.0, 0.0, 9.0, 0.0)))
        .radius(Is(5.0))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .presses(Is(true))
        .says(By(fn() { Some(@view.said(Radio, label=name, selected=at() == i)) }))
        .on_press(fn() { pick(i) })
        .ground(By(fn() {
          if at() == i {
            0x3A3C42FFL
          } else if b.pointed() {
            0xFFFFFF0FL
          } else {
            0L
          }
        }))
        |> ignore
        b.box(fn(t) {
          t
          .words(Is(name), look={ ..@view.words_plain, size: 12.0, weight: 500, line: 16.0, wrap: false })
          .ink(By(fn() { if at() == i { set_ink } else { set_muted } }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    }
  })
  |> ignore
}

///|
fn switch(parent : @view.View, on : () -> Bool, set : (Bool) -> Unit) -> Unit {
  parent.box(fn(s) {
    s
    .width(Is(Some(36.0)))
    .height(Is(Some(20.0)))
    .radius(Is(10.0))
    .shrink(Is(0.0))
    .presses(Is(true))
    .says(By(fn() { Some(@view.said(Switch, label="", check=if on() { On } else { Off })) }))
    .on_press(fn() { set(!on()) })
    .ground(By(fn() { if on() { 0x2F9BFFFFL } else { 0x3A3C42FFL } }))
    .lines_up(Is(Some(Start)))
    .lies_along(Is(Middle))
    |> ignore
    s.box(fn(k) {
      k
      .width(Is(Some(16.0)))
      .height(Is(Some(16.0)))
      .radius(Is(8.0))
      .ground(Is(0xFFFFFFFFL))
      .offset(By(fn() { (if on() { 18.0 } else { 2.0 }, 0.0) }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn small_button(parent : @view.View, label : String, press : () -> Unit) -> Unit {
  parent.box(fn(b) {
    b
    .height(Is(Some(26.0)))
    .padding(Is((10.0, 0.0, 10.0, 0.0)))
    .radius(Is(6.0))
    .shrink(Is(0.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .says(Is(Some(@view.said(Button, label~))))
    .on_press(press)
    .ground(By(fn() { if b.pointed() { 0x45474EFFL } else { 0x3A3C42FFL } }))
    |> ignore
    b.box(fn(t) {
      t.words(Is(label), look={ ..@view.words_plain, size: 12.0, weight: 500, line: 16.0, wrap: false }).ink(Is(set_ink)) |> ignore
    })
    |> ignore
  })
  |> ignore
}
