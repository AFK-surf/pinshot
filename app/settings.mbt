// The settings (settings.json in %APPDATA%\PinShot) and their window: the shortcuts, how a pin opens, where pictures
// are saved, and whether PinShot starts with Windows. A change is written and in force at once.

///|
#derive(Eq)
struct Settings {
  /// the shortcuts: capture, and pin the clipboard's picture (set by pressing them on Windows; picked from
  /// `key_choices` and `pin_choices` on the Mac)
  capture_key : Hotkey
  pin_key : Hotkey
  /// a pin over the other windows as it opens, and how clear (255 not seen through)
  pin_top : Bool
  pin_alpha : Int
  /// saving: format (0 PNG lossless, 1 JPEG 92%, 2 JPEG 80%), the system's dialog each time (else straight into the
  /// folder), the folder, and a copy kept there too
  save_format : Int
  ask_where : Bool
  save_dir : String
  keep_copies : Bool
  /// whether WGC capture sessions stay open in the background (true: instant capture; false: opened on demand to save
  /// ~245 MB of idle video memory)
  capture_keep : Bool
  /// the language: 0 the system's, 1 Chinese, 2 English (i18n.mbt)
  language : Int
  /// a shutter's sound as a capture is copied, saved or pinned
  sound : Bool
  /// updates asked for once a day and put in place once nobody uses PinShot (update.mbt); off (as it starts: the user,
  /// 2026-11-19: 「自动更新默认关掉」), PinShot goes online only when 检查更新 is pressed
  auto_update : Bool
}

///|
/// The shortcuts offered: their words, and Windows' modifiers (Alt 1, Ctrl 2, Shift 4) and key. The first of each is
/// what PixPin is set to on the person's machine (the user, 2026-11-17: 「快捷键对齐一下」): Ctrl+Alt+A takes the
/// screen, Ctrl+2 pins the clipboard's picture; the others are PixPin's and Snipaste's defaults.
let key_choices : Array[(String, Int, Int)] = if @hostapi.platform() == 0 {
  [("⌃⌥A", 3, 0x41), ("⌃1", 2, 0x31), ("F1", 0, 0x70), ("⌃⇧A", 6, 0x41)]
} else {
  [("Ctrl+Alt+A", 3, 0x41), ("Ctrl+1", 2, 0x31), ("F1", 0, 0x70),
   ("Ctrl+Shift+A", 6, 0x41), ("PrtSc", 0, 0x2C)]
}

///|
let pin_choices : Array[(String, Int, Int)] = [
  (if @hostapi.platform() == 0 { "⌃2" } else { "Ctrl+2" }, 2, 0x32),
  ("F3", 0, 0x72),
  ("F2", 0, 0x71),
  ("不用快捷键", 0, 0),
]

///|
/// A shortcut: Windows' modifiers (Alt 1, Ctrl 2, Shift 4, Win 8, as RegisterHotKey takes them) and virtual key; none
/// where `vk` is 0. The Mac's ps_hotkey takes the same, for the keys `key_choices` and `pin_choices` offer.
#derive(Eq)
struct Hotkey {
  mods : Int
  vk : Int
}

///|
fn hotkey_of(c : (String, Int, Int)) -> Hotkey {
  { mods: c.1, vk: c.2 }
}

///|
/// Whether shortcuts are set by pressing them (Windows: the user, 2026-11-20 「快捷键都支持一下自定义」); elsewhere they
/// are picked from `key_choices` and `pin_choices`.
fn keys_pressed_in() -> Bool {
  @hostapi.platform() == 3
}

///|
/// A shortcut as it is shown: one of `choices` by its name, else its modifiers and key ("Ctrl+Alt+A").
fn key_words(h : Hotkey, choices : Array[(String, Int, Int)]) -> String {
  if h.vk == 0 {
    return tr("未设置")
  }
  for c in choices {
    if c.1 == h.mods && c.2 == h.vk {
      return tr(c.0)
    }
  }
  let parts : Array[String] = []
  if (h.mods & 2) != 0 {
    parts.push("Ctrl")
  }
  if (h.mods & 1) != 0 {
    parts.push("Alt")
  }
  if (h.mods & 4) != 0 {
    parts.push("Shift")
  }
  if (h.mods & 8) != 0 {
    parts.push("Win")
  }
  parts.push(text_of(ps_key_name(h.vk)))
  parts.join("+")
}

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
    capture_key: hotkey_of(key_choices[0]),
    pin_key: hotkey_of(pin_choices[0]),
    pin_top: true,
    pin_alpha: 255,
    save_format: 0,
    ask_where: true,
    save_dir: text_of(ps_pictures_dir()),
    keep_copies: false,
    capture_keep: true,
    sound: true,
    language: 0,
    auto_update: false,
  }
}

///|
let settings : @signals.Signal[Settings] = @signals.signal({
  capture_key: hotkey_of(key_choices[0]),
  pin_key: hotkey_of(pin_choices[0]),
  pin_top: true,
  pin_alpha: 255,
  save_format: 0,
  ask_where: true,
  save_dir: "",
  keep_copies: false,
  capture_keep: true,
  sound: true,
  language: 0,
  auto_update: false,
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
  file_in(text_of(ps_data_dir()), "settings.json")
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
      // (a shortcut as {"mods","vk"}; one kept by an older PinShot by its choice's name)
      let hotkey = fn(name : String, older : String, choices : Array[(String, Int, Int)]) -> Hotkey {
        match o.get(name) {
          Some(Json::Object(k)) =>
            match (k.get("mods"), k.get("vk")) {
              (Some(Number(m, ..)), Some(Number(v, ..))) => { mods: m.to_int() & 15, vk: v.to_int() & 255 }
              _ => hotkey_of(choices[0])
            }
          _ => hotkey_of(choices[choice_named(choices, text(older, choices[0].0))])
        }
      }
      {
        capture_key: hotkey("capture_key", "capture_keys", key_choices),
        pin_key: hotkey("pin_key", "pin_keys", pin_choices),
        pin_top: flag("pin_top", d.pin_top),
        pin_alpha: clampi(num("pin_alpha", d.pin_alpha), 25, 255),
        save_format: match text("save_format", "png") {
          "jpg-92" => 1
          "jpg-80" => 2
          _ => 0
        },
        ask_where: flag("ask_where", d.ask_where),
        save_dir: text("save_dir", d.save_dir),
        keep_copies: flag("keep_copies", d.keep_copies),
        capture_keep: flag("capture_keep", d.capture_keep),
        sound: flag("sound", d.sound),
        auto_update: flag("auto_update", d.auto_update),
        language: match text("language", "system") {
          "zh" => 1
          "en" => 2
          _ => 0
        },
      }
    }
    _ => d
  }
  settings.set(s)
  apply_language(s.language)
  ps_set_capture_keep(if s.capture_keep { 1 } else { 0 })
  autostart.set(ps_autostart() == 1)
}

///|
fn save_settings() -> Unit {
  let s = settings.untracked()
  let o : Map[String, Json] = Map([])
  let hotkey = fn(h : Hotkey) {
    let k : Map[String, Json] = Map([])
    k["mods"] = Json::number(h.mods.to_double())
    k["vk"] = Json::number(h.vk.to_double())
    Json::object(k)
  }
  o["capture_key"] = hotkey(s.capture_key)
  o["pin_key"] = hotkey(s.pin_key)
  o["pin_top"] = Json::boolean(s.pin_top)
  o["pin_alpha"] = Json::number(s.pin_alpha.to_double())
  o["save_format"] = Json::string(["png", "jpg-92", "jpg-80"][s.save_format])
  o["ask_where"] = Json::boolean(s.ask_where)
  o["save_dir"] = Json::string(s.save_dir)
  o["keep_copies"] = Json::boolean(s.keep_copies)
  o["capture_keep"] = Json::boolean(s.capture_keep)
  o["sound"] = Json::boolean(s.sound)
  o["auto_update"] = Json::boolean(s.auto_update)
  o["language"] = Json::string(["system", "zh", "en"][s.language])
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
  if s.capture_keep != was.capture_keep {
    ps_set_capture_keep(if s.capture_keep { 1 } else { 0 })
  }
  if s.language != was.language {
    apply_language(s.language)
  }
  if s.capture_key != was.capture_key || s.pin_key != was.pin_key || s.language != was.language {
    apply_keys()
  }
}

///|
/// The shortcuts set as the settings say, and the icon's menu naming them.
fn apply_keys() -> Unit {
  let s = settings.untracked()
  let cw = key_words(s.capture_key, key_choices)
  let pw = key_words(s.pin_key, pin_choices)
  let pv = s.pin_key.vk
  capture_key_ok.set(ps_hotkey(1, s.capture_key.mods, s.capture_key.vk) == 1)
  pin_key_ok.set(ps_hotkey(2, s.pin_key.mods, pv) == 1)
  log("keys: capture \{cw} \{if capture_key_ok.untracked() { "ok" } else { "taken by another program" }}, pin \{pw} \{if pin_key_ok.untracked() { "ok" } else { "taken by another program" }}")
  // (a shortcut another program holds said once, as it is found: PixPin started with Windows holds Ctrl+Alt+A)
  if !capture_key_ok.untracked() {
    ps_tray_note(
      cstr(tr("截图快捷键被其他程序占用：") + cw),
      cstr(tr("点这里打开 PinShot 设置换一个；或者退出占用它的程序（比如 PixPin）后重新打开 PinShot。")),
    )
  }
  let pin_words = if pv == 0 { tr("贴图剪贴板中的图片") } else { tr("贴图剪贴板中的图片") + "\u{8}" + pw }
  let menu = "capture\t" +
    tr("截图") +
    "\u{8}" +
    cw +
    "\npin-clip\t" +
    pin_words +
    "\npins\t" +
    tr("显示/隐藏全部贴图") +
    "\n-\nsettings\t" +
    tr("设置…") +
    "\nfolder\t" +
    tr("打开截图文件夹") +
    (if updates_here() { "\ncheck-update\t" + tr("检查更新…") } else { "" }) +
    "\n-\nquit\t" +
    tr("退出 PinShot") +
    "\n"
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
  ps_center(wid, 680, 450)
}

// ---- a shortcut set by pressing it (Windows) ----

///|
/// The shortcut being set by pressing it: 1 capture's, 2 pinning the clipboard's, 0 none.
let recording : @signals.Signal[Int] = @signals.signal(0)

///|
/// Why the last shortcut pressed was not taken (shown under its row till another is asked for): its row (1, 2; 0
/// none) and the words.
let key_trouble : @signals.Signal[(Int, String)] = @signals.signal((0, ""))

///|
/// The shortcut `which` asked for (its box pressed): both let go meanwhile, so the one pressed is taken, not run; its box
/// pressed again while it waits puts things back as they were.
fn record_key(which : Int) -> Unit {
  let was = recording.untracked()
  stop_recording()
  key_trouble.set((0, ""))
  if was == which {
    apply_keys()
    return
  }
  ps_hotkey(1, 0, 0) |> ignore
  ps_hotkey(2, 0, 0) |> ignore
  if ps_key_record(1) == 1 {
    recording.set(which)
  } else {
    apply_keys()
  }
}

///|
/// Waiting for a shortcut no more (the settings closed, or another asked for), nothing taken.
fn stop_recording() -> Unit {
  if recording.untracked() != 0 {
    ps_key_record(0) |> ignore
    recording.set(0)
  }
}

///|
/// A key pressed while a shortcut was asked for (ps_key_record): taken as it, unless it is not one a person can use
/// (a plain key with no Ctrl, Alt or Win, but F1-F24, PrtSc, Pause and Scroll Lock), the other shortcut already, or
/// another program's. Escape gives up, Backspace or Delete leaves pinning the clipboard with none (capture keeps one).
fn key_pressed(how : String, mods : Int, vk : Int) -> Unit {
  let which = recording.untracked()
  recording.set(0)
  if which == 0 {
    return
  }
  let was = settings.untracked()
  let trouble = fn(why : String) {
    key_trouble.set((which, why))
    apply_keys()
  }
  match how {
    "cancel" => {
      apply_keys()
      return
    }
    "clear" => {
      if which == 2 {
        change_settings(fn(s) { { ..s, pin_key: { mods: 0, vk: 0 } } })
        apply_keys()
      } else {
        trouble(tr("截图必须有快捷键"))
      }
      return
    }
    _ => ()
  }
  let h : Hotkey = { mods, vk }
  let alone = (vk >= 0x70 && vk <= 0x87) || vk == 0x2C || vk == 0x13 || vk == 0x91
  if (mods & 11) == 0 && !alone {
    trouble(tr("要和 Ctrl、Alt 或 Win 一起按（F1–F24、PrtSc 可以单独用）"))
    return
  }
  let other = if which == 1 { was.pin_key } else { was.capture_key }
  if other == h {
    trouble(if which == 1 { tr("和「贴剪贴板图片」的快捷键相同") } else { tr("和「截图」的快捷键相同") })
    return
  }
  // (tried as it is now, both let go: one another program holds is said, the old one kept)
  if ps_hotkey(which, mods, vk) != 1 {
    trouble(key_words(h, []) + tr(" 已被其他程序占用，换一个"))
    return
  }
  log("keys: \{if which == 1 { "capture" } else { "pin" }} set to \{key_words(h, [])}")
  if which == 1 {
    change_settings(fn(s) { { ..s, capture_key: h } })
  } else {
    change_settings(fn(s) { { ..s, pin_key: h } })
  }
  apply_keys()
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
/// The settings' pages (the user, 2026-11-20: the list of pages at the side, as PixPin's): which one shows.
let settings_tab : @signals.Signal[Int] = @signals.signal(0)

///|
let settings_tabs : Array[String] = ["常规", "快捷键", "截图与贴图", "关于"]

///|
fn settings_window(root : @view.View) -> Unit {
  root.tree.hand_over_presses(false)
  root.box(fn(w) {
    w.over(Is(true)).ground(Is(set_ground)).row(Is(true)) |> ignore
    w.box(fn(side) {
      side.width(Is(Some(168.0))).shrink(Is(0.0)).padding(Is((12.0, 16.0, 12.0, 16.0))).gap(Is(2.0)) |> ignore
      for i, name in settings_tabs {
        side.box(fn(t) {
          t
          .row(Is(true))
          .height(Is(Some(34.0)))
          .padding(Is((12.0, 0.0, 12.0, 0.0)))
          .radius(Is(7.0))
          .lines_up(Is(Some(Middle)))
          .presses(Is(true))
          .says(By(fn() { Some(@view.said(Radio, label=tr(name), selected=settings_tab.get() == i)) }))
          .on_press(fn() { settings_tab.set(i) })
          .ground(By(fn() {
            if settings_tab.get() == i {
              set_card
            } else if t.pointed() {
              0xFFFFFF0FL
            } else {
              0L
            }
          }))
          |> ignore
          t.box(fn(x) {
            x
            .words(By(fn() { tr(name) }), look={ ..@view.words_plain, size: 13.0, weight: 500, line: 18.0, wrap: false })
            .ink(By(fn() { if settings_tab.get() == i { set_ink } else { set_muted } }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
      }
    })
    |> ignore
    w.box(fn(line) { line.width(Is(Some(1.0))).shrink(Is(0.0)).ground(Is(0xFFFFFF14L)) |> ignore }) |> ignore
    w.box(fn(main) {
      main.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      main.box(fn(viewport) {
        viewport.over(Is(true)).scrolls(@view.Scroll::new(), fn(page) {
          page.padding(Is((22.0, 18.0, 22.0, 20.0))) |> ignore
          let pages : Array[(@view.View) -> Unit] = [general_page, keys_page, capture_page, about_page]
          for i, make in pages {
            page.box(fn(p) {
              p.laid_nowhere(By(fn() { settings_tab.get() != i })).gap(Is(12.0)) |> ignore
              set_words(p, fn() { tr(settings_tabs[i]) }, 16.0, set_ink, weight=600)
              make(p)
            })
            |> ignore
          }
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn general_page(p : @view.View) -> Unit {
  set_group(p, "", fn(g) {
    set_row(g, "语言", fn(r) {
      choice(r, language_names, fn() { settings.get().language }, fn(i) {
        change_settings(fn(s) { { ..s, language: i } })
      })
    })
    set_row(g, "开机时启动", fn(r) {
      switch(r, fn() { autostart.get() }, fn(on) {
        if ps_set_autostart(if on { 1 } else { 0 }) == 1 {
          autostart.set(on)
        }
      })
    })
    set_row(g, "快门音效", fn(r) {
      switch(r, fn() { settings.get().sound }, fn(on) {
        change_settings(fn(s) { { ..s, sound: on } })
        if on {
          ps_shutter()
        }
      })
    }, note=fn() { tr("复制、保存、贴图时播放") }, note_ink=fn() { set_muted })
    if @hostapi.platform() == 3 {
      set_row(
        g,
        "截屏模式",
        fn(r) {
          choice(r, ["极速常驻", "按需省显存"], fn() { if settings.get().capture_keep { 0 } else { 1 } }, fn(i) {
            change_settings(fn(s) { { ..s, capture_keep: i == 0 } })
          })
        },
        note=fn() {
          if settings.get().capture_keep {
            tr("后台保持截屏会话，按键秒开")
          } else {
            tr("平时不占截屏显存（省约 240 MB），按键时拉起")
          }
        },
        note_ink=fn() { set_muted },
      )
    }
  })
}

///|
fn keys_page(p : @view.View) -> Unit {
  set_group(p, "", fn(g) {
    if keys_pressed_in() {
      set_row(g, "截图", fn(r) { key_box(r, 1) }, note=fn() { key_note(1) })
      set_row(g, "贴剪贴板图片", fn(r) { key_box(r, 2) }, note=fn() { key_note(2) })
    } else {
      set_row(g, "截图", fn(r) {
        choice(
          r,
          key_choices.map(fn(c) { c.0 }),
          fn() { choice_of(key_choices, settings.get().capture_key) },
          fn(i) { change_settings(fn(s) { { ..s, capture_key: hotkey_of(key_choices[i]) } }) },
        )
      }, note=fn() { key_note(1) })
      set_row(g, "贴剪贴板图片", fn(r) {
        choice(
          r,
          pin_choices.map(fn(c) { c.0 }),
          fn() { choice_of(pin_choices, settings.get().pin_key) },
          fn(i) { change_settings(fn(s) { { ..s, pin_key: hotkey_of(pin_choices[i]) } }) },
        )
      }, note=fn() { key_note(2) })
    }
  })
  if keys_pressed_in() {
    p.box(fn(b) {
      b.padding(Is((4.0, 0.0, 4.0, 0.0))) |> ignore
      set_words(b, fn() { tr("点一下快捷键框，再按下想用的组合键；Esc 取消，退格键清除。") }, 12.0, set_muted)
    })
    |> ignore
  }
}

///|
/// Which of `choices` the shortcut `h` is (the first where none is).
fn choice_of(choices : Array[(String, Int, Int)], h : Hotkey) -> Int {
  for i, c in choices {
    if c.1 == h.mods && c.2 == h.vk {
      return i
    }
  }
  0
}

///|
/// What is said under a shortcut's row: why the one pressed was not taken, or that another program holds it.
fn key_note(which : Int) -> String {
  let (row, why) = key_trouble.get()
  if row == which {
    why
  } else if !(if which == 1 { capture_key_ok.get() } else { pin_key_ok.get() }) {
    tr("已被其他程序占用，换一个")
  } else {
    ""
  }
}

///|
/// A shortcut's box: what it is; pressed, it waits for the keys to be pressed ("按下快捷键…").
fn key_box(parent : @view.View, which : Int) -> Unit {
  let words = fn() {
    if recording.get() == which {
      tr("按下快捷键…")
    } else if which == 1 {
      key_words(settings.get().capture_key, key_choices)
    } else {
      key_words(settings.get().pin_key, pin_choices)
    }
  }
  parent.box(fn(b) {
    b
    .min_width(Is(Some(160.0)))
    .height(Is(Some(28.0)))
    .padding(Is((12.0, 0.0, 12.0, 0.0)))
    .radius(Is(8.0))
    .shrink(Is(0.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .says(By(fn() { Some(@view.said(Button, label=words())) }))
    .on_press(fn() { record_key(which) })
    .edge(By(fn() { (1.0, if recording.get() == which { 0x2F9BFFFFL } else { 0xFFFFFF14L }) }))
    .ground(By(fn() {
      if recording.get() == which {
        0x17324FFFL
      } else if b.pointed() {
        0x2C2E33FFL
      } else {
        0x17181BFFL
      }
    }))
    |> ignore
    b.box(fn(t) {
      t
      .words(By(words), look={ ..@view.words_plain, size: 12.5, weight: 500, line: 16.0, wrap: false })
      .ink(By(fn() { if recording.get() == which { 0x8CC8FFFFL } else { set_ink } }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn capture_page(p : @view.View) -> Unit {
  set_group(p, "保存", fn(g) {
    set_row(g, "图片格式", fn(r) {
      choice(r, ["PNG 无损", "JPEG 高清", "JPEG 小体积"], fn() { settings.get().save_format }, fn(i) {
        change_settings(fn(s) { { ..s, save_format: i } })
      })
    })
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
      small_button(r, fn() { tr("打开") }, fn() { ps_reveal(cstr(settings.untracked().save_dir)) })
    })
  })
  set_group(p, "贴图", fn(g) {
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
}

///|
fn about_page(p : @view.View) -> Unit {
  set_group(p, "", fn(g) {
    update_settings(g)
    // (the sponsor's page: the user, 2026-11-19 「给 PinShot 也加一个赞助链接」)
    set_row(g, "赞助作者", fn(r) {
      small_button(r, fn() { tr("赞助") }, fn() {
        ps_open_url(cstr(site_url + "/support?lang=" + (if english.get() { "en" } else { "zh" })))
      })
    }, note=fn() { tr("PinShot 免费使用，觉得好用可以请我喝杯咖啡") }, note_ink=fn() { set_muted })
  })
  p.box(fn(b) {
    b.padding(Is((4.0, 0.0, 4.0, 0.0))).gap(Is(2.0)) |> ignore
    set_words(b, fn() {
      if updates_here() {
        tr("免费、无广告，不收集任何数据；只在检查更新时联网。")
      } else {
        tr("免费、无广告，不联网、不收集任何数据。")
      }
    }, 12.0, set_muted)
    set_words(b, fn() { "© 2026 pengx17" }, 12.0, set_muted)
  })
  |> ignore
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
    if title != "" {
      set_words(g, fn() { tr(title) }, 12.0, set_muted, weight=500)
    }
    g.box(fn(card) {
      card.ground(Is(set_card)).radius(Is(12.0)).edge(Is((1.0, 0xFFFFFF14L))).padding(Is((14.0, 4.0, 14.0, 4.0))) |> ignore
      make(card)
    })
    |> ignore
  })
  |> ignore
}

///|
fn set_row(
  parent : @view.View,
  label : String,
  make : (@view.View) -> Unit,
  note? : () -> String = fn() { "" },
  note_ink? : () -> Int64 = fn() { 0xE5A545FFL },
) -> Unit {
  parent.box(fn(row) {
    row
    .row(Is(true))
    .min_height(Is(Some(38.0)))
    .padding(Is((0.0, 5.0, 0.0, 5.0)))
    .gap(Is(12.0))
    .lines_up(Is(Some(Middle)))
    |> ignore
    row.box(fn(l) {
      l.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).gap(Is(2.0)) |> ignore
      set_words(l, fn() { tr(label) }, 13.0, set_ink)
      l.box(fn(n) {
        n
        .laid_nowhere(By(fn() { note() == "" }))
        .words(By(note), look={ ..@view.words_plain, size: 11.5, weight: 400, line: 16.0, wrap: true })
        .ink(By(note_ink))
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
    seg.row(Is(true)).pad(Is(2.0)).radius(Is(8.0)).ground(Is(0x17181BFFL)).gap(Is(2.0)).shrink(Is(0.0)) |> ignore
    for i, name in names {
      seg.box(fn(b) {
        b
        .height(Is(Some(26.0)))
        .padding(Is((9.0, 0.0, 9.0, 0.0)))
        .radius(Is(6.0))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .presses(Is(true))
        .says(By(fn() { Some(@view.said(Radio, label=tr(name), selected=at() == i)) }))
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
          .words(By(fn() { tr(name) }), look={ ..@view.words_plain, size: 12.0, weight: 500, line: 16.0, wrap: false })
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
/// A small button saying `label` (it may change), laid out only while `shown`.
fn small_button(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  shown? : () -> Bool = fn() { true },
  min_width? : () -> Double? = fn() { None },
) -> Unit {
  parent.box(fn(b) {
    b
    .laid_nowhere(By(fn() { !shown() }))
    .min_width(By(min_width))
    .height(Is(Some(26.0)))
    .padding(Is((10.0, 0.0, 10.0, 0.0)))
    .radius(Is(8.0))
    .shrink(Is(0.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .says(By(fn() { Some(@view.said(Button, label=label())) }))
    .on_press(press)
    .ground(By(fn() { if b.pointed() { 0x45474EFFL } else { 0x3A3C42FFL } }))
    |> ignore
    b.box(fn(t) {
      t.words(By(label), look={ ..@view.words_plain, size: 12.0, weight: 500, line: 16.0, wrap: false }).ink(Is(set_ink)) |> ignore
    })
    |> ignore
  })
  |> ignore
}
