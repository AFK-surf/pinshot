// Pins: a picture kept over the other windows (a part just captured, where it was; or the clipboard's picture), each a
// window of this run beside the overlay (mbui's window_open_here: the same program, no start of its own), with no
// frame, at its picture's own pixels. Dragged anywhere to move it; the wheel zooms it about the pointer; Ctrl and the
// wheel make it fainter or clearer; a double click or Esc closes it; its right click is its menu (copy, save, over the
// others or not, as big as it is, how clear, close).

///|
struct Pin {
  wid : Ref[Int]
  key : String
  png : Bytes
  w : Int
  h : Int
  zoom : @signals.Signal[Double]
  alpha : @signals.Signal[Int]
  top : @signals.Signal[Bool]
  /// when its zoom last changed (its label shown a moment)
  zoomed_at : @signals.Signal[Double]
}

///|
/// The pins by what each window was opened for ("pin:N").
let pins : Map[String, Pin] = Map([])

///|
let pin_n : Ref[Int] = Ref(0)

///|
/// Whether the pins are out of sight (the shortcut that hides and shows them all).
let pins_hidden : Ref[Bool] = Ref(false)

///|
/// A pin of `png` (w by h pixels) opened at x, y on the screen.
fn open_pin(png : Bytes, x : Int, y : Int, w : Int, h : Int) -> Unit {
  pin_n.val += 1
  let what = "pin:\{pin_n.val}"
  let key = "mem:" + what
  @ui.add_image(key, png)
  let s = settings.untracked()
  let p : Pin = {
    wid: Ref(0),
    key,
    png,
    w,
    h,
    zoom: @signals.signal(1.0),
    alpha: @signals.signal(s.pin_alpha),
    top: @signals.signal(s.pin_top),
    zoomed_at: @signals.signal(-10000.0),
  }
  pins[what] = p
  let wid = @ui.window_open_here(what)
  if wid <= 0 {
    println("pin: no window (\{pins.length()} open)")
    pins.remove(what)
    @ui.forget_image(key)
    return
  }
  p.wid.val = wid
  ps_own(wid, if s.pin_top { 1 } else { 0 }) |> ignore
  ps_shadow(wid)
  ps_place(wid, x, y, w, h, 1, 1)
  if s.pin_alpha < 255 {
    ps_opacity(wid, s.pin_alpha)
  }
  pins_hidden.val = false
  log("pin \{w}x\{h} opened (\{pins.length()} open)")
}

///|
/// The clipboard's picture pinned by the pointer (none there: nothing).
fn pin_clipboard() -> Unit {
  // (a test run: the clipboard as if it held none, the person's left alone)
  let b = if @ui.env("PINSHOT_TEST_NO_CLIP") != "" { Bytes::new(0) } else { ps_clipboard_image() }
  guard b.length() > 0 && @pixels.image_size(b) is Some((w, h)) else {
    log("pin: no picture on the clipboard")
    toast("剪贴板里没有图片")
    return
  }
  let p = numbers_of(text_of(ps_pointer()))
  let (x, y) = if p.length() == 2 { (p[0].to_int() - w / 2, p[1].to_int() - h / 2) } else { (100, 100) }
  open_pin(b, x, y, w, h)
}

///|
fn pin_of_wid(wid : Int) -> (String, Pin)? {
  for what, p in pins {
    if p.wid.val == wid {
      return Some((what, p))
    }
  }
  None
}

///|
fn close_pin(wid : Int) -> Unit {
  guard pin_of_wid(wid) is Some((_, _)) else { return }
  close_window(wid)
}

///|
/// A pin's window gone (closed here or by the system): what it held let go.
fn pin_gone(wid : Int) -> Unit {
  guard pin_of_wid(wid) is Some((what, p)) else { return }
  pins.remove(what)
  @ui.forget_image(p.key)
  trim_soon()
}

///|
/// Every pin over the others and in front now; or, where they are out of sight, shown again; the shortcut's.
fn pins_to_front() -> Unit {
  for _, p in pins {
    ps_topmost(p.wid.val, if p.top.untracked() { 1 } else { 0 }, 0)
    ps_place_show(p.wid.val)
  }
  pins_hidden.val = false
}

///|
/// The shortcut that hides the pins and shows them again.
fn pins_toggle() -> Unit {
  if pins.is_empty() {
    return
  }
  if pins_hidden.val {
    pins_to_front()
  } else {
    for _, p in pins {
      ps_hide(p.wid.val)
    }
    pins_hidden.val = true
  }
}

///|
fn ps_place_show(wid : Int) -> Unit {
  let r = numbers_of(text_of(ps_window_rect(wid)))
  if r.length() >= 4 {
    ps_place(wid, r[0].to_int(), r[1].to_int(), r[2].to_int(), r[3].to_int(), 1, 0)
  }
}

///|
/// The pin zoomed to `z` (0.1 to 8), about the pointer where it is over it.
fn zoom_pin(p : Pin, z : Double) -> Unit {
  let z = clamp(z, 0.1, 8.0)
  let r = numbers_of(text_of(ps_window_rect(p.wid.val)))
  if r.length() < 4 {
    return
  }
  let (x, y, w, h) = (r[0], r[1], r[2], r[3])
  let nw = dmax(16.0, (p.w.to_double() * z).round())
  let nh = dmax(16.0, (p.h.to_double() * z).round())
  let q = numbers_of(text_of(ps_pointer()))
  let (ax, ay) = if q.length() == 2 && q[0] >= x && q[0] < x + w && q[1] >= y && q[1] < y + h {
    (q[0], q[1])
  } else {
    (x + w / 2.0, y + h / 2.0)
  }
  let nx = ax - (ax - x) * nw / w
  let ny = ay - (ay - y) * nh / h
  p.zoom.set(z)
  p.zoomed_at.set(now_of(p))
  ps_place(p.wid.val, nx.round().to_int(), ny.round().to_int(), nw.to_int(), nh.to_int(), 0, 0)
}

///|
let pin_roots : Map[Int, @view.View] = Map([])

///|
fn now_of(p : Pin) -> Double {
  match pin_roots.get(p.wid.val) {
    Some(r) => r.cause_at()
    None => 0.0
  }
}

///|
fn set_alpha(p : Pin, a : Int) -> Unit {
  let a = clampi(a, 25, 255)
  p.alpha.set(a)
  ps_opacity(p.wid.val, a)
  p.zoomed_at.set(now_of(p))
}

///|
fn copy_pin(p : Pin) -> Unit {
  @hostapi.clipboard_set_image(p.png)
}

///|
fn save_pin(p : Pin) -> Unit {
  let s = settings.untracked()
  let path = text_of(ps_save_dialog(p.wid.val, cstr(s.save_dir), cstr(file_name())))
  if path != "" {
    ps_write_file(cstr(path), p.png) |> ignore
  }
}

///|
/// The pin's menu at the pointer.
fn pin_menu(p : Pin) -> Unit {
  let top = p.top.untracked()
  let a = p.alpha.untracked()
  let z = p.zoom.untracked()
  let lines = [
    "copy\t复制\tCtrl+C", "save\t另存为…\t", "-", "top\t置顶\t" + (if top { "c" } else { "" }), "front\t移到最前\t",
    "-", "zoom1\t原始大小 (100%)\t" + (if z == 1.0 { "c" } else { "" }), "a100\t不透明度 100%\t" + (if a >= 255 { "c" } else { "" }),
    "a80\t不透明度 80%\t" + (if a == 204 { "c" } else { "" }), "a60\t不透明度 60%\t" + (if a == 153 { "c" } else { "" }),
    "a40\t不透明度 40%\t" + (if a == 102 { "c" } else { "" }), "-", "close\t关闭\tEsc", "close-all\t关闭全部贴图\t",
  ]
  let chose = text_of(ps_popup_menu(p.wid.val, @utf8.encode(menu_lines(lines))))
  match chose {
    "copy" => copy_pin(p)
    "save" => save_pin(p)
    "top" => {
      p.top.set(!top)
      ps_topmost(p.wid.val, if top { 0 } else { 1 }, 0)
    }
    "front" => ps_topmost(p.wid.val, if top { 1 } else { 0 }, 1)
    "zoom1" => zoom_pin(p, 1.0)
    "a100" => set_alpha(p, 255)
    "a80" => set_alpha(p, 204)
    "a60" => set_alpha(p, 153)
    "a40" => set_alpha(p, 102)
    "close" => close_pin(p.wid.val)
    "close-all" => {
      let wids = pins.values().map(fn(q) { q.wid.val }).collect()
      for w in wids {
        close_pin(w)
      }
    }
    _ => ()
  }
}

///|
/// The menu's lines as the native side reads them: "key\twords\tflags", a key's hint after the words (a tab between:
/// Windows' menus put it at their right).
fn menu_lines(lines : Array[String]) -> String {
  let sb = StringBuilder()
  for l in lines {
    if l == "-" {
      sb.write_string("-\n")
      continue
    }
    let parts : Array[String] = l.split("\t").map(fn(s) { s.to_owned() }).collect()
    let key = parts[0]
    let words = if parts.length() > 1 { parts[1] } else { "" }
    let third = if parts.length() > 2 { parts[2] } else { "" }
    let (hint, flags) = if third == "c" || third == "g" || third == "" { ("", third) } else { (third, "") }
    sb.write_string(key)
    sb.write_char('\t')
    sb.write_string(words)
    if hint != "" {
      sb.write_string("\u{8}" + hint)
    }
    sb.write_char('\t')
    sb.write_string(flags)
    sb.write_char('\n')
  }
  sb.to_string()
}

///|
/// A pin's window, made as it opens.
fn pin_window(wid : Int, what : String) -> (@view.View) -> Unit {
  fn(root) {
    guard pins.get(what) is Some(p) else { return }
    p.wid.val = wid
    pin_roots[wid] = root
    root.tree.hand_over_presses(false)
    root
    .ground(Is(0x000000FFL))
    .keymap(Is(pin_keys()))
    .presses(Is(true))
    .cursor(Is(Some(Arrow)))
    .on_drag(fn(d) {
      if d.kind == Down {
        @hostapi.window_drag()
      }
    }, whole=true)
    .on_double_press(fn() { close_pin(wid) })
    .on_menu(fn(_) { pin_menu(p) })
    .on_wheel(fn(w) {
      // (Ctrl: how clear; else the zoom, a notch 10% of it)
      let notch = if w.dy > 0.0 { 1.0 } else if w.dy < 0.0 { -1.0 } else { 0.0 }
      if notch == 0.0 {
        return
      }
      if (w.mods & @ui.wheel_mod_ctrl) != 0 {
        set_alpha(p, p.alpha.untracked() - (notch * 26.0).to_int())
      } else {
        let z = p.zoom.untracked()
        zoom_pin(p, (z * (if notch < 0.0 { 1.1 } else { 1.0 / 1.1 }) * 100.0).round() / 100.0)
      }
    })
    |> ignore
    let px = if p.w > p.h { p.w } else { p.h }
    root.box(fn(i) { i.over(Is(true)).image(Is(Some((p.key, "", px)))).presses(Is(false)) |> ignore }) |> ignore
    // (its edge: a hairline, the accent while the pointer is on it)
    root.box(fn(e) {
      e.over(Is(true)).presses(Is(false)).edge(By(fn() { if root.pointed() { (1.0, accent) } else { (1.0, 0x8C919966L) } })) |> ignore
    })
    |> ignore
    // (its zoom and how clear it is, a moment after either changes)
    root.box(fn(o) {
      o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(End))).lies_along(Is(End)).padding(Is((6.0, 6.0, 6.0, 6.0))) |> ignore
      o.box(fn(l) {
        l
        .height(Is(Some(20.0)))
        .padding(Is((6.0, 0.0, 6.0, 0.0)))
        .radius(Is(4.0))
        .ground(Is(0x17181BD9L))
        .lines_up(Is(Some(Middle)))
        .laid_nowhere(By(fn() { root.drawn_past(p.zoomed_at.get() + 900.0) }))
        |> ignore
        l.box(fn(t) {
          t
          .words(By(fn() {
            let a = p.alpha.get()
            "\{(p.zoom.get() * 100.0).round().to_int()}%" + (if a < 255 { "  ·  \{a * 100 / 255}%" } else { "" })
          }), look={ ..@view.words_plain, size: 11.0, weight: 500, line: 14.0, wrap: false })
          .ink(Is(0xEDEEF0FFL))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    pin_actions(root, p)
  }
}

///|
fn pin_keys() -> @view.Keymap {
  let k = fn(code : Int, action : String, mods : Int) -> @view.Binding {
    { keys: [{ code, mods }], action, when: Always }
  }
  let ch = fn(c : Char, action : String, mods : Int) { k(@ui.key_of_char(c), action, mods) }
  @view.Keymap::new([
    k(@ui.key_escape, "close", 0),
    ch('c', "copy", @ui.mod_ctrl),
    ch('s', "save", @ui.mod_ctrl),
    ch('t', "top", @ui.mod_ctrl),
    ch('0', "zoom1", @ui.mod_ctrl),
  ])
}

///|
fn pin_actions(root : @view.View, p : Pin) -> Unit {
  let on = fn(name : String, f : () -> Unit) {
    root.on_action(name, fn(_) {
      f()
      true
    })
    |> ignore
  }
  on("close", fn() { close_pin(p.wid.val) })
  on("copy", fn() { copy_pin(p) })
  on("save", fn() { save_pin(p) })
  on("top", fn() {
    let top = !p.top.untracked()
    p.top.set(top)
    ps_topmost(p.wid.val, if top { 1 } else { 0 }, 0)
  })
  on("zoom1", fn() { zoom_pin(p, 1.0) })
}
