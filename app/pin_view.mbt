// Floating Pin-to-screen window (`--pin <path> <x> <y> <w> <h>`):
// Borderless topmost window, drag to move, wheel to zoom, Ctrl+wheel for opacity, double-click or Esc to close.

///|
let pin_x : Ref[Int] = Ref(100)

///|
let pin_y : Ref[Int] = Ref(100)

///|
let pin_base_w : Ref[Int] = Ref(400)

///|
let pin_base_h : Ref[Int] = Ref(300)

///|
let pin_zoom : Ref[Double] = Ref(1.0)

///|
let pin_opacity : Ref[Int] = Ref(255)

///|
let pin_path : Ref[String] = Ref("")

///|
let pin_png_bytes : Ref[Bytes] = Ref(b"")

///|
let pin_topmost : @signals.Signal[Bool] = @signals.signal(true)

///|
fn pin_toggle_topmost() -> Unit {
  let next = !pin_topmost.untracked()
  pin_topmost.set(next)
  ps_set_topmost(if next { 1 } else { 0 })
}

///|
fn pin_apply_zoom(z : Double) -> Unit {
  let nz = clamp(z, 0.25, 4.0)
  pin_zoom.val = nz
  let nw = @cmp.maximum(48, (pin_base_w.val.to_double() * nz).round().to_int())
  let nh = @cmp.maximum(48, (pin_base_h.val.to_double() * nz).round().to_int())
  ps_show_popup(pin_x.val, pin_y.val, nw, nh)
  if !pin_topmost.untracked() {
    ps_set_topmost(0)
  }
}

///|
fn pin_close() -> Unit {
  if pin_path.val != "" {
    ps_delete_file(cstr(pin_path.val))
  }
  @ui.window_close_here(0)
}

///|
fn pin_window_view(root : @view.View) -> Unit {
  let bindings = @view.Keymap::new([
    @view.Binding::{ keys: [@view.Stroke::{ code: 0x1B, mods: 0 }], action: "close", when: Always },
    @view.Binding::{ keys: [@view.Stroke::{ code: 'C'.to_int(), mods: 2 }], action: "copy", when: Always },
    @view.Binding::{ keys: [@view.Stroke::{ code: 'S'.to_int(), mods: 2 }], action: "save", when: Always },
    @view.Binding::{ keys: [@view.Stroke::{ code: 'T'.to_int(), mods: 0 }], action: "toggle_topmost", when: Always },
    @view.Binding::{ keys: [@view.Stroke::{ code: 'F'.to_int(), mods: 0 }], action: "front", when: Always },
  ])
  root.keymap(Is(bindings)) |> ignore
  root.on_action("close", fn(_) {
    pin_close()
    true
  }) |> ignore
  root.on_action("toggle_topmost", fn(_) {
    pin_toggle_topmost()
    true
  }) |> ignore
  root.on_action("front", fn(_) {
    pin_topmost.set(true)
    ps_set_topmost(1)
    true
  }) |> ignore
  root.on_action("copy", fn(_) {
    if pin_png_bytes.val.length() > 0 {
      @ui.clipboard_set_png(pin_png_bytes.val)
    }
    true
  }) |> ignore
  root.on_action("save", fn(_) {
    if pin_png_bytes.val.length() > 0 {
      ps_save_png_dialog(pin_png_bytes.val, cstr("PinShot.png")) |> ignore
    }
    true
  }) |> ignore

  root.box(fn(card) {
    card
    .grow(Is(1.0))
    .presses(Is(true))
    .moves_window(Is(true))
    .edge(By(fn() {
      if pin_topmost.get() { (1.5, 0x3B82F6CCL) } else { (1.5, 0x71717AAAL) }
    }))
    .on_wheel(fn(e) {
      if (e.mods & @ui.wheel_mod_ctrl) != 0 {
        let delta = if e.dy > 0.0 { 18 } else { -18 }
        pin_opacity.val = @cmp.maximum(60, @cmp.minimum(255, pin_opacity.val + delta))
        ps_set_opacity(pin_opacity.val)
      } else {
        let factor = if e.dy > 0.0 { 1.1 } else { 0.9 }
        pin_apply_zoom(pin_zoom.val * factor)
      }
    })
    .on_double_press(fn() { pin_close() })
    .on_menu(fn(_) { pin_close() })
    |> ignore

    card.box(fn(img) {
      img
      .over(Is(true))
      .presses(Is(false))
      .grow(Is(1.0))
      .image(Is(Some(("pin-img", "", 4096))))
      .image_contains(Is(true))
      |> ignore
    }) |> ignore

    // Hover mini pill in top-right corner
    card.box(fn(pill) {
      pill
      .over(Is(true))
      .row(Is(true))
      .gap(Is(2.0))
      .padding(Is((4.0, 3.0, 4.0, 3.0)))
      .radius(Is(6.0))
      .ground(Is(0x18181BD8L))
      .edge(Is((1.0, 0xFFFFFF22L)))
      .lies_along(Is(End))
      .margin(Is((0.0, 6.0, 6.0, 0.0)))
      .laid_nowhere(By(fn() { !card.pointer_within() }))
      |> ignore
      tb_btn(pill, "置顶", fn() { pin_topmost.get() }, pin_toggle_topmost)
      tb_btn(pill, "1:1", fn() { false }, fn() { pin_apply_zoom(1.0) })
      tb_btn(pill, "复制", fn() { false }, fn() {
        if pin_png_bytes.val.length() > 0 {
          @ui.clipboard_set_png(pin_png_bytes.val)
        }
      })
      tb_btn(pill, "×", fn() { false }, pin_close)
    }) |> ignore
  }) |> ignore
}
