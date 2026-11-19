// Pins: a picture kept over the other windows (a part just captured, where it was; or the clipboard's picture), each a
// window of this run beside the overlay (mbui's window_open_here: the same program, no start of its own), with no
// frame, at its picture's own pixels. Dragged anywhere to move it; dragged by an edge (8 points of it) to stretch it
// that way alone, by a corner to make it bigger or smaller as it is (Shift: freely), the opposite side staying where it
// was; the wheel zooms it about the pointer; Ctrl and the wheel make it fainter or clearer; a double click or Esc closes
// it; its right click is its menu (copy, save, over the others or not, turned a quarter either way, flipped either way,
// put back as it was pinned, how clear, close).

///|
struct Pin {
  wid : Ref[Int]
  /// the picture as it was pinned (what a reset puts back)
  first_png : Bytes
  first_w : Int
  first_h : Int
  /// the picture as it is turned now (what is shown, copied and saved), its key among the images and its pixels
  key : @signals.Signal[String]
  /// what its pictures' keys start with ("mem:pin:N:")
  key_base : String
  mut png : Bytes
  mut w : Int
  mut h : Int
  /// how its picture is turned from how it was pinned: flipped across first (`flip`), then turned `turn` quarters
  /// clockwise (0..3); (0, false) is as it was pinned
  mut turn : Int
  mut flip : Bool
  /// how big it is drawn across and down, to its picture's pixels (each 0.1 to 8; apart, it is stretched)
  zx : @signals.Signal[Double]
  zy : @signals.Signal[Double]
  alpha : @signals.Signal[Int]
  top : @signals.Signal[Bool]
  /// when its zoom last changed (its label shown a moment)
  zoomed_at : @signals.Signal[Double]
  /// whether it is the window in front (its frame the accent's), and since when, while it flashes as it is taken
  active : @signals.Signal[Bool]
  active_at : @signals.Signal[Double]
  flash : @signals.Signal[Double]
  /// which of its edges the pointer is by (pin_edge: 1 left, 2 right, 4 top, 8 bottom; 0 inside): the cursor's
  edge : @signals.Signal[Int]
  /// a drag by an edge under way: none, or where it went down
  sizing : Ref[PinSizing?]
}

///|
/// A pin being sized by an edge or a corner: which (pin_edge's bits), its window as the press went down (x, y, w, h,
/// the screen's pixels), its zoom across and down then, and the pointer then.
struct PinSizing {
  edge : Int
  x : Double
  y : Double
  w : Double
  h : Double
  zx : Double
  zy : Double
  px : Double
  py : Double
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
  let key_base = "mem:" + what + ":"
  let key = key_base + "0"
  @ui.add_image(key, png)
  let s = settings.untracked()
  let p : Pin = {
    wid: Ref(0),
    first_png: png,
    first_w: w,
    first_h: h,
    key: @signals.signal(key),
    key_base,
    png,
    w,
    h,
    turn: 0,
    flip: false,
    zx: @signals.signal(1.0),
    zy: @signals.signal(1.0),
    alpha: @signals.signal(s.pin_alpha),
    top: @signals.signal(s.pin_top),
    zoomed_at: @signals.signal(-10000.0),
    active: @signals.signal(false),
    active_at: @signals.signal(-10000.0),
    flash: @signals.signal(0.0),
    edge: @signals.signal(0),
    sizing: Ref(None),
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
  let b = if @ui.env("PINSHOT_TEST_NO_CLIP") != "" {
    Bytes::make(0, b'\x00')
  } else if @ui.env("PINSHOT_TEST_PIN_FILE") != "" {
    ps_read_file(cstr(@ui.env("PINSHOT_TEST_PIN_FILE")))
  } else {
    ps_clipboard_image()
  }
  guard b.length() > 0 && @pixels.image_size(b) is Some((w, h)) else {
    log("pin: no picture on the clipboard")
    toast(tr("剪贴板里没有图片"))
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
  @ui.forget_image(p.key.untracked())
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
/// The pin at `zx` by `zy` of its picture's pixels (each 0.1 to 8), about the pointer where it is over it, else its
/// middle.
fn zoom_pin(p : Pin, zx : Double, zy : Double) -> Unit {
  let zx = clamp(zx, 0.1, 8.0)
  let zy = clamp(zy, 0.1, 8.0)
  let r = numbers_of(text_of(ps_window_rect(p.wid.val)))
  if r.length() < 4 {
    return
  }
  let (x, y, w, h) = (r[0], r[1], r[2], r[3])
  let nw = dmax(16.0, (p.w.to_double() * zx).round())
  let nh = dmax(16.0, (p.h.to_double() * zy).round())
  let q = numbers_of(text_of(ps_pointer()))
  let (ax, ay) = if q.length() == 2 && q[0] >= x && q[0] < x + w && q[1] >= y && q[1] < y + h {
    (q[0], q[1])
  } else {
    (x + w / 2.0, y + h / 2.0)
  }
  let nx = ax - (ax - x) * nw / w
  let ny = ay - (ay - y) * nh / h
  p.zx.set(zx)
  p.zy.set(zy)
  p.zoomed_at.set(now_of(p))
  ps_place(p.wid.val, nx.round().to_int(), ny.round().to_int(), nw.to_int(), nh.to_int(), 0, 0)
  p.edge.set(pin_edge(p))
}

///|
/// The pin zoomed by `k` as it is (a wheel's notch), neither side past 0.1 or 8.
fn scale_pin(p : Pin, k : Double) -> Unit {
  let (zx, zy) = (p.zx.untracked(), p.zy.untracked())
  let k = clamp(k, dmax(0.1 / zx, 0.1 / zy), dmin(8.0 / zx, 8.0 / zy))
  let r = fn(z : Double) { (z * k * 100.0).round() / 100.0 }
  zoom_pin(p, r(zx), r(zy))
}

///|
/// The pin with picture `png` (`w` by `h`, `turn` and `flip` from how it was pinned) at `zx` by `zy`, kept about its
/// middle: what turning, flipping and putting it back do.
fn repicture_pin(p : Pin, png : Bytes, w : Int, h : Int, turn : Int, flip : Bool, zx : Double, zy : Double) -> Unit {
  let r = numbers_of(text_of(ps_window_rect(p.wid.val)))
  if r.length() < 4 {
    return
  }
  let old = p.key.untracked()
  pin_key_n.val += 1
  let key = p.key_base + pin_key_n.val.to_string()
  @ui.add_image(key, png)
  p.png = png
  p.w = w
  p.h = h
  p.turn = turn
  p.flip = flip
  p.key.set(key)
  @ui.forget_image(old)
  trim_soon()
  let (cx, cy) = (r[0] + r[2] / 2.0, r[1] + r[3] / 2.0)
  let nw = dmax(16.0, (w.to_double() * zx).round())
  let nh = dmax(16.0, (h.to_double() * zy).round())
  p.zx.set(zx)
  p.zy.set(zy)
  p.zoomed_at.set(now_of(p))
  ps_place(p.wid.val, (cx - nw / 2.0).round().to_int(), (cy - nh / 2.0).round().to_int(), nw.to_int(), nh.to_int(), 0, 0)
  p.edge.set(pin_edge(p))
}

///|
/// For the images' keys of turned pictures.
let pin_key_n : Ref[Int] = Ref(0)

///|
/// The pin put into orientation `(turn, flip)` from `first_png` at `zx` by `zy`: where `(0, false)` is back as it was
/// pinned, `first_png` is used directly without re-encoding or keeping two copies.
fn orient_pin(p : Pin, turn : Int, flip : Bool, zx : Double, zy : Double) -> Unit {
  if turn == 0 && !flip {
    repicture_pin(p, p.first_png, p.first_w, p.first_h, 0, false, zx, zy)
    return
  }
  guard picture_rgba(p.first_png) is Some((w0, h0, px)) else {
    log("pin: its picture could not be read to turn or flip it")
    return
  }
  let (w, h, out) = transform_rgba(w0, h0, px, turn, flip)
  repicture_pin(p, @pixels.png(w, h, out), w, h, turn, flip, zx, zy)
}

///|
/// The pin turned a quarter clockwise (`cw`) or the other way: its picture's pixels turned, its sides and zooms swapped.
fn turn_pin(p : Pin, cw : Bool) -> Unit {
  let next_turn = (p.turn + (if cw { 1 } else { 3 })) & 3
  orient_pin(p, next_turn, p.flip, p.zy.untracked(), p.zx.untracked())
}

///|
/// The pin flipped left to right (`across`) or top to bottom: its picture's pixels mirrored, its size kept.
fn flip_pin(p : Pin, across : Bool) -> Unit {
  let next_turn = (if across { 4 - p.turn } else { 2 - p.turn }) & 3
  orient_pin(p, next_turn, !p.flip, p.zx.untracked(), p.zy.untracked())
}

///|
/// RGBA pixels `w0` by `h0` mirrored left to right if `flip`, then turned `turn` quarters clockwise (0..3).
fn transform_rgba(w0 : Int, h0 : Int, px : FixedArray[Byte], turn : Int, flip : Bool) -> (Int, Int, FixedArray[Byte]) {
  let (ow, oh) = if (turn & 1) == 1 { (h0, w0) } else { (w0, h0) }
  let out = FixedArray::make(w0 * h0 * 4, b'\x00')
  for y in 0..<h0 {
    for x in 0..<w0 {
      let fx = if flip { w0 - 1 - x } else { x }
      let (nx, ny) = match turn & 3 {
        1 => (h0 - 1 - y, fx)
        2 => (w0 - 1 - fx, h0 - 1 - y)
        3 => (y, w0 - 1 - fx)
        _ => (fx, y)
      }
      let i = (y * w0 + x) * 4
      let o = (ny * ow + nx) * 4
      out[o] = px[i]
      out[o + 1] = px[i + 1]
      out[o + 2] = px[i + 2]
      out[o + 3] = px[i + 3]
    }
  }
  (ow, oh, out)
}

///|
/// The pin put back as it was pinned: its picture neither turned nor flipped, its own pixels' size, not stretched.
fn reset_pin(p : Pin) -> Unit {
  if p.turn != 0 || p.flip {
    repicture_pin(p, p.first_png, p.first_w, p.first_h, 0, false, 1.0, 1.0)
  } else {
    zoom_pin(p, 1.0, 1.0)
  }
}

///|
/// Whether the pin is as it was pinned.
fn pin_as_pinned(p : Pin) -> Bool {
  p.turn == 0 && !p.flip && p.zx.untracked() == 1.0 && p.zy.untracked() == 1.0
}

///|
/// A picture's pixels (RGBA, a row after another), as a pin has it: a PNG, a JPEG or a BMP (the clipboard's bitmap).
fn picture_rgba(b : Bytes) -> (Int, Int, FixedArray[Byte])? {
  match @pixels.decode_png(b) {
    Some(r) => Some(r)
    None =>
      match @pixels.decode_jpeg(b) {
        Some(r) => Some(r)
        None => bmp_rgba(b)
      }
  }
}

///|
/// A BMP's pixels (32 or 24 bits a pixel, uncompressed or of bit fields as Windows' clipboard writes it; its rows
/// from the foot up, or from the top where its height is below 0): RGBA.
fn bmp_rgba(b : Bytes) -> (Int, Int, FixedArray[Byte])? {
  let n = b.length()
  let u8 = fn(i : Int) -> Int { if i >= 0 && i < n { b[i].to_int() } else { 0 } }
  let le32 = fn(i : Int) -> Int { u8(i) | (u8(i + 1) << 8) | (u8(i + 2) << 16) | (u8(i + 3) << 24) }
  if n < 54 || u8(0) != 0x42 || u8(1) != 0x4D {
    return None
  }
  let off = le32(10)
  let w = le32(18)
  let h0 = le32(22)
  let bpp = u8(28) | (u8(29) << 8)
  let comp = le32(30)
  let (h, down) = if h0 < 0 { (-h0, true) } else { (h0, false) }
  if w <= 0 || h <= 0 || (bpp != 32 && bpp != 24) || (comp != 0 && comp != 3) {
    return None
  }
  let bpx = bpp / 8
  let stride = (w * bpx + 3) / 4 * 4
  if off + stride * h > n {
    return None
  }
  // (32 bits whose alpha is all 0: an old bitmap's, opaque)
  let mut any_alpha = false
  if bpp == 32 {
    for y in 0..<h {
      for x in 0..<w {
        if u8(off + y * stride + x * 4 + 3) != 0 {
          any_alpha = true
          break
        }
      }
      if any_alpha {
        break
      }
    }
  }
  let out = FixedArray::make(w * h * 4, b'\xff')
  for y in 0..<h {
    let row = off + (if down { y } else { h - 1 - y }) * stride
    for x in 0..<w {
      let i = row + x * bpx
      let o = (y * w + x) * 4
      out[o] = b[i + 2]
      out[o + 1] = b[i + 1]
      out[o + 2] = b[i]
      if bpp == 32 && any_alpha {
        out[o + 3] = b[i + 3]
      }
    }
  }
  Some((w, h, out))
}

///|
/// Which of pin `p`'s edges the pointer is by now (within 8 points of it, at most a quarter of the pin in from it):
/// 1 left, 2 right, 4 top, 8 bottom, a corner two of them; 0 inside it, or not over it.
fn pin_edge(p : Pin) -> Int {
  let r = numbers_of(text_of(ps_window_rect(p.wid.val)))
  let q = numbers_of(text_of(ps_pointer()))
  if r.length() < 5 || q.length() < 2 {
    return 0
  }
  let (x, y, w, h) = (r[0], r[1], r[2], r[3])
  let (px, py) = (q[0] - x, q[1] - y)
  if px < 0.0 || py < 0.0 || px >= w || py >= h {
    return 0
  }
  let band = 8.0 * dmax(r[4], 96.0) / 96.0
  let bx = dmin(band, w / 4.0)
  let by = dmin(band, h / 4.0)
  let ex = if px < bx { 1 } else if px >= w - bx { 2 } else { 0 }
  let ey = if py < by { 4 } else if py >= h - by { 8 } else { 0 }
  ex | ey
}

///|
/// The pointer's shape by edge `e` (pin_edge's).
fn edge_cursor(e : Int) -> @view.Cursor {
  match e {
    5 | 10 => ResizeNWSE
    6 | 9 => ResizeNESW
    1 | 2 => ResizeX
    4 | 8 => ResizeY
    _ => Arrow
  }
}

///|
/// Pin `p` sized by the drag `s` begun, the pointer where it is now: by an edge stretched that way alone, by a corner as
/// it is (its proportions then kept, by how far the pointer went along its diagonal; Shift held: freely), each zoom 0.1 to
/// 8 as the wheel's, the opposite side or corner staying where it was.
fn size_pin(p : Pin, s : PinSizing) -> Unit {
  let q = numbers_of(text_of(ps_pointer()))
  if q.length() < 2 || s.w <= 0.0 || s.h <= 0.0 {
    return
  }
  let (dx, dy) = (q[0] - s.px, q[1] - s.py)
  let (l, r, t, b) = ((s.edge & 1) != 0, (s.edge & 2) != 0, (s.edge & 4) != 0, (s.edge & 8) != 0)
  let sx = (s.w + (if r { dx } else if l { -dx } else { 0.0 })) / s.w
  let sy = (s.h + (if b { dy } else if t { -dy } else { 0.0 })) / s.h
  let across = l || r
  let down = t || b
  let (kx, ky) = if across && down && ps_shift_down() == 0 {
    // (the pointer's way taken along the pin's diagonal: one size, going on smoothly whichever side it moves more along,
    // where taking the side moved further jumped between the two as they crossed; the user, 2026-11-18: 「这里会突然跳很多」)
    let k = (sx * s.w * s.w + sy * s.h * s.h) / (s.w * s.w + s.h * s.h)
    let k = clamp(k, dmax(0.1 / s.zx, 0.1 / s.zy), dmin(8.0 / s.zx, 8.0 / s.zy))
    (k, k)
  } else {
    (if across { sx } else { 1.0 }, if down { sy } else { 1.0 })
  }
  let zx = clamp(s.zx * kx, 0.1, 8.0)
  let zy = clamp(s.zy * ky, 0.1, 8.0)
  let nw = dmax(16.0, (p.w.to_double() * zx).round())
  let nh = dmax(16.0, (p.h.to_double() * zy).round())
  let nx = if l { s.x + s.w - nw } else { s.x }
  let ny = if t { s.y + s.h - nh } else { s.y }
  p.zx.set(zx)
  p.zy.set(zy)
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
    write_picture_file(path, p.png)
  }
}

///|
/// The pin's menu at the pointer.
fn pin_menu(p : Pin) -> Unit {
  let top = p.top.untracked()
  let a = p.alpha.untracked()
  let o = tr("不透明度")
  let lines = [
    "copy\t" + tr("复制") + "\tCtrl+C", "save\t" + tr("另存为…") + "\t", "ocr\t" + tr("提取文字") + "\t", "-", "top\t" + tr("置顶") + "\t" + (if top { "c" } else { "" }),
    "front\t" + tr("移到最前") + "\t", "-", "turn-ccw\t" + tr("向左旋转 90°") + "\tCtrl+Shift+R",
    "turn-cw\t" + tr("向右旋转 90°") + "\tCtrl+R",
    "flip-x\t" + tr("水平翻转") + "\t", "flip-y\t" + tr("垂直翻转") + "\t", "reset\t" + tr("重置") + "\t" + (if pin_as_pinned(p) { "g" } else { "Ctrl+0" }), "-",
    "a100\t\{o} 100%\t" + (if a >= 255 { "c" } else { "" }), "a80\t\{o} 80%\t" + (if a == 204 { "c" } else { "" }),
    "a60\t\{o} 60%\t" + (if a == 153 { "c" } else { "" }), "a40\t\{o} 40%\t" + (if a == 102 { "c" } else { "" }), "-",
    "close\t" + tr("关闭") + "\tEsc", "close-all\t" + tr("关闭全部贴图") + "\t",
  ]
  let chose = text_of(ps_popup_menu(p.wid.val, @utf8.encode(menu_lines(lines))))
  match chose {
    "copy" => copy_pin(p)
    "save" => save_pin(p)
    "ocr" => read_words(p.png)
    "top" => {
      p.top.set(!top)
      ps_topmost(p.wid.val, if top { 0 } else { 1 }, 0)
    }
    "front" => ps_topmost(p.wid.val, if top { 1 } else { 0 }, 1)
    "turn-ccw" => turn_pin(p, false)
    "turn-cw" => turn_pin(p, true)
    "flip-x" => flip_pin(p, true)
    "flip-y" => flip_pin(p, false)
    "reset" => reset_pin(p)
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
    .cursor(By(fn() { Some(edge_cursor(p.edge.get())) }))
    .on_pointer_moved(fn() { if p.sizing.val is None { p.edge.set(pin_edge(p)) } })
    .on_drag(fn(d) {
      // (by an edge or a corner: sized as the pointer goes, till it is let go)
      match p.sizing.val {
        Some(s) if d.kind != Down => {
          if d.kind == Moved {
            pin_last_down.val = (0, 0.0, 0.0, 0.0)
            size_pin(p, s)
          } else {
            p.sizing.val = None
            p.edge.set(pin_edge(p))
          }
          return
        }
        _ => ()
      }
      if d.kind == Down {
        p.sizing.val = None
        // (the second press of a double click closes it: told here, mbui's double press is not told of a node that
        // drags)
        let t = ps_now_ms()
        let (lw, lt, lx, ly) = pin_last_down.val
        if lw == wid && t - lt <= 500.0 && (d.x - lx).abs() <= 4.0 && (d.y - ly).abs() <= 4.0 {
          pin_last_down.val = (0, 0.0, 0.0, 0.0)
          close_pin(wid)
          return
        }
        pin_last_down.val = (wid, t, d.x, d.y)
        let e = pin_edge(p)
        p.edge.set(e)
        if e != 0 {
          let r = numbers_of(text_of(ps_window_rect(wid)))
          let q = numbers_of(text_of(ps_pointer()))
          if r.length() >= 4 && q.length() >= 2 {
            p.sizing.val = Some({
              edge: e,
              x: r[0],
              y: r[1],
              w: r[2],
              h: r[3],
              zx: p.zx.untracked(),
              zy: p.zy.untracked(),
              px: q[0],
              py: q[1],
            })
            return
          }
        }
        // (moved by the system's own move, the press then let go of as the move ends: mbui hears no release from
        // it, and took the next press for one, every other press not moving the pin)
        ps_move_window(wid)
      }
    }, whole=true)
    .on_menu(fn(_) { pin_menu(p) })
    .on_wheel(fn(w) {
      if p.sizing.val is Some(_) {
        return
      }
      // (Ctrl: how clear; else the zoom, a notch 10% of it)
      let notch = if w.dy > 0.0 { 1.0 } else if w.dy < 0.0 { -1.0 } else { 0.0 }
      if notch == 0.0 {
        return
      }
      if (w.mods & @ui.wheel_mod_ctrl) != 0 {
        set_alpha(p, p.alpha.untracked() - (notch * 26.0).to_int())
      } else {
        scale_pin(p, if notch < 0.0 { 1.1 } else { 1.0 / 1.1 })
      }
    })
    |> ignore
    let px = if p.w > p.h { p.w } else { p.h }
    root.box(fn(i) { i.over(Is(true)).image(By(fn() { Some((p.key.get(), "", px)) })).presses(Is(false)) |> ignore })
    |> ignore
    // (its edge: a hairline; the accent's while the pointer is on it; the window in front, a frame of the accent, and
    // as it is taken a flash: the frame comes in thick and narrows as a tint of the accent over it fades, 360 ms; the
    // user, 2026-11-17: 「选中pin的图片时应该有更强的动画提示」)
    root.box(fn(e) {
      e
      .over(Is(true))
      .presses(Is(false))
      .ground(By(fn() {
        let f = pin_flash(e, p)
        if f <= 0.0 {
          0L
        } else {
          0x2F9BFF00L | (f * 70.0).round().to_int64()
        }
      }))
      .edge(By(fn() {
        let f = pin_flash(e, p)
        // (its own pixels a point here; DWM's frame over its outermost pixel)
        if f > 0.001 {
          (3.0 + 7.0 * f, accent)
        } else if p.active.get() {
          (3.0, accent)
        } else if root.pointed() {
          (2.0, accent)
        } else {
          (1.0, 0x8C919966L)
        }
      }))
      |> ignore
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
        .lies_along(Is(Middle))
        .laid_nowhere(By(fn() { root.drawn_past(p.zoomed_at.get() + 900.0) }))
        |> ignore
        l.box(fn(t) {
          t
          .words(By(fn() {
            let a = p.alpha.get()
            let pc = fn(z : Double) { (z * 100.0).round().to_int() }
            let (zx, zy) = (pc(p.zx.get()), pc(p.zy.get()))
            (if zx == zy { "\{zx}%" } else { "\{zx}% × \{zy}%" }) +
            (if a < 255 { "  ·  \{a * 100 / 255}%" } else { "" })
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
    ch('0', "reset", @ui.mod_ctrl),
    ch('r', "turn-cw", @ui.mod_ctrl),
    ch('r', "turn-ccw", @ui.mod_ctrl | @ui.mod_shift_key),
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
  on("reset", fn() { reset_pin(p) })
  on("turn-cw", fn() { turn_pin(p, true) })
  on("turn-ccw", fn() { turn_pin(p, false) })
}

///|
/// How much of its flash is left (1 as it is taken, 0 once it is over).
fn pin_flash(_n : @view.View, p : Pin) -> Double {
  p.flash.get()
}

///|
/// A frame of pin window `wid` asked for as it is taken (platform_win.c, every 16 ms for a while): its flash as of
/// now, eased out (quick at first) over 360 ms.
fn pin_tick(wid : Int) -> Unit {
  guard pin_of_wid(wid) is Some((_, p)) else { return }
  let x = clamp((ps_now_ms() - p.active_at.untracked()) / 360.0, 0.0, 1.0)
  let e = 1.0 - (1.0 - x) * (1.0 - x) * (1.0 - x)
  p.flash.set(1.0 - e)
}

///|
/// Pin window `wid` taken as the window in front (`on`) or let go: its frame, and a flash as it is taken.
fn pin_active(wid : Int, on : Bool) -> Unit {
  guard pin_of_wid(wid) is Some((_, p)) else { return }
  p.active.set(on)
  if !on {
    return
  }
  p.active_at.set(ps_now_ms())
  p.flash.set(1.0)
}

///|
/// The last press on a pin: its window, when, where (points): the first of a double click.
let pin_last_down : Ref[(Int, Double, Double, Double)] = Ref((0, 0.0, 0.0, 0.0))
