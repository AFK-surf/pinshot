// Minimal "installed" welcome window shown once after double-clicking the single-file installer (launched with
// `--installed`): confirms installation visibly (Win11 often suppresses legacy tray balloons), shows active shortcuts,
// offers an instant Start-with-Windows toggle, and links to Settings. Zero overhead when closed.

///|
let welcome_wid : Ref[Int] = Ref(0)

///|
fn open_welcome() -> Unit {
  if welcome_wid.val > 0 && @ui.window_front_here(welcome_wid.val) {
    return
  }
  let wid = @ui.window_open_here("welcome")
  if wid <= 0 {
    return
  }
  welcome_wid.val = wid
  ps_center(wid, 412, 306)
}

///|
fn close_welcome() -> Unit {
  if welcome_wid.val > 0 {
    let wid = welcome_wid.val
    welcome_wid.val = 0
    close_window(wid)
  }
}

///|
fn welcome_keycap(parent : @view.View, text : () -> String, ok : () -> Bool) -> Unit {
  parent.box(fn(k) {
    k
    .height(Is(Some(24.0)))
    .padding(Is((9.0, 0.0, 9.0, 0.0)))
    .radius(Is(6.0))
    .shrink(Is(0.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .ground(Is(0x141518FFL))
    .edge(By(fn() { (1.0, if ok() { 0xFFFFFF26L } else { 0xE5A54580L }) }))
    |> ignore
    k.box(fn(t) {
      t
      .words(By(text), look={ ..@view.words_plain, size: 12.0, weight: 500, line: 16.0, wrap: false })
      .ink(By(fn() { if ok() { set_ink } else { 0xE5A545FFL } }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn welcome_button(parent : @view.View, label : () -> String, primary : Bool, press : () -> Unit) -> Unit {
  parent.box(fn(b) {
    let hov = smooth_hover(b)
    tactile_press(b)
    b
    .height(Is(Some(32.0)))
    .padding(Is((if primary { 16.0 } else { 14.0 }, 0.0, if primary { 16.0 } else { 14.0 }, 0.0)))
    .radius(Is(8.0))
    .shrink(Is(0.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .cursor(Is(Some(Hand)))
    .says(By(fn() { Some(@view.said(Button, label=label())) }))
    .on_press(press)
    .ground(By(fn() {
      if primary {
        if b.pressed() { 0x2584E6FFL } else { mix_rgba(0x2F9BFFFFL, 0x49AAFFFFL, hov()) }
      } else if b.pressed() {
        0x3F434FFFL
      } else {
        mix_rgba(0x2A2D36FFL, 0x363A46FFL, hov())
      }
    }))
    .edge(Is((1.0, if primary { 0xFFFFFF24L } else { 0xFFFFFF1EL })))
    |> ignore
    b.box(fn(t) {
      t
      .words(By(label), look={ ..@view.words_plain, size: 12.5, weight: if primary { 600 } else { 500 }, line: 16.0, wrap: false })
      .ink(Is(if primary { 0xFFFFFFFFL } else { set_ink }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn welcome_window(root : @view.View) -> Unit {
  root.tree.hand_over_presses(false)
  let k = fn(code : Int, action : String) -> @view.Binding {
    { keys: [{ code, mods: 0 }], action, when: Always }
  }
  root.keymap(Is(@view.Keymap::new([k(@ui.key_escape, "close"), k(@ui.key_code_enter, "close")]))) |> ignore
  root.on_action("close", fn(_) {
    close_welcome()
    true
  })
  |> ignore
  root.box(fn(w) {
    w.over(Is(true)).ground(Is(set_ground)).padding(Is((24.0, 22.0, 24.0, 20.0))).gap(Is(16.0)) |> ignore
    // Header: emerald check badge + installed version & subtitle
    w.box(fn(hdr) {
      hdr.row(Is(true)).gap(Is(14.0)).lines_up(Is(Some(Middle))) |> ignore
      hdr.box(fn(badge) {
        badge
        .width(Is(Some(42.0)))
        .height(Is(Some(42.0)))
        .shrink(Is(0.0))
        .radius(Is(11.0))
        .ground(Is(0x22C55E1CL))
        .edge(Is((1.0, 0x22C55E4AL)))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        |> ignore
        badge.box(fn(ic) {
          ic
          .width(Is(Some(20.0)))
          .height(Is(Some(20.0)))
          .picture(Is(Some({ w: 16.0, h: 16.0, layers: [stroke_layer("M3.4 8.5L6.6 11.7L12.8 5.2", 0x4ADE80FFL, 2.0)] })))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      hdr.box(fn(col) {
        col.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).gap(Is(3.0)) |> ignore
        set_words(col, fn() { "PinShot " + app_version + tr(" 已安装") }, 16.0, set_ink, weight=600)
        col.box(fn(sub) {
          sub
          .words(By(fn() { tr("已添加到开始菜单，正在系统托盘待命") }), look={ ..@view.words_plain, size: 12.0, weight: 400, line: 17.0, wrap: true })
          .ink(Is(set_muted))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // Quick summary card: active shortcuts + start-at-login toggle
    set_group(w, "", fn(g) {
      set_row(g, "开始截图", fn(r) {
        welcome_keycap(r, fn() { key_words(settings.get().capture_key, key_choices) }, fn() { capture_key_ok.get() })
      })
      set_row(g, "贴剪贴板图片", fn(r) {
        welcome_keycap(r, fn() { key_words(settings.get().pin_key, pin_choices) }, fn() { pin_key_ok.get() })
      })
      set_row(g, "开机时启动", fn(r) {
        switch(r, fn() { autostart.get() }, fn(on) {
          if ps_set_autostart(if on { 1 } else { 0 }) == 1 {
            autostart.set(on)
          }
        })
      })
    })
    // Subtle management / uninstall hint
    w.box(fn(note) {
      note
      .padding(Is((2.0, 0.0, 2.0, 0.0)))
      .words(By(fn() { tr("可随时从系统托盘图标或「设置 › 应用」管理与卸载。") }), look={ ..@view.words_plain, size: 11.5, weight: 400, line: 16.0, wrap: true })
      .ink(Is(0x8E94A3FFL))
      |> ignore
    })
    |> ignore
    // Spacer pushing footer to bottom
    w.box(fn(sp) { sp.grow(Is(1.0)) |> ignore }) |> ignore
    // Footer actions
    w.box(fn(foot) {
      foot.row(Is(true)).lies_along(Is(End)).gap(Is(8.0)) |> ignore
      welcome_button(foot, fn() { tr("打开设置") }, false, fn() {
        close_welcome()
        open_settings()
      })
      welcome_button(foot, fn() { tr("开始使用") }, true, fn() { close_welcome() })
    })
    |> ignore
  })
  |> ignore
}
