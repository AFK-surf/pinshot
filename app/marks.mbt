// The marks drawn on a capture: boxes, ovals, arrows, pen lines, numbered dots, mosaic and words. Each is kept in the
// monitor's pixels (where the picture's pixels are), so the overlay draws it at its scale and a copy draws it at the
// picture's own, the same marks both ways (export.mbt). Undone and done again a mark at a time.

///|
/// What a press on the picked part does: nothing of its own (it moves the part), or draws a mark of a kind.
#derive(Eq, Debug)
enum Tool {
  Move
  Box
  Oval
  Arrow
  Pen
  Mosaic
  Number
  Words
}

///|
/// A mark: of what kind, its points (two corners or an arrow's tail and head; a pen's line; a number's or words' place),
/// its colour (RGBA), how thick (0 thin, 1, 2 thick), a number's number, words' words.
#derive(Eq)
struct Mark {
  id : Int
  tool : Tool
  pts : Array[(Double, Double)]
  color : Int64
  size : Int
  n : Int
  words : String
}

///|
let marks : @signals.Signal[Array[Mark]] = @signals.signal_by([], same=fn(a, b) { physical_equal(a, b) })

///|
/// The mark being drawn now (None: none).
let draft : @signals.Signal[Mark?] = @signals.signal_by(None, same=fn(a, b) { physical_equal(a, b) })

///|
let undone : Ref[Array[Array[Mark]]] = Ref([])

///|
let done_before : Ref[Array[Array[Mark]]] = Ref([])

///|
let mark_ids : Ref[Int] = Ref(0)

///|
let tool : @signals.Signal[Tool] = @signals.signal(Move)

///|
/// The colours a mark is drawn in, the first red.
let colors : Array[Int64] = [0xF5383BFFL, 0xFFB020FFL, 0x2ECC71FFL, 0x2F80EDFFL, 0xFFFFFFFFL, 0x111214FFL]

///|
let color_now : @signals.Signal[Int64] = @signals.signal(0xF5383BFFL)

///|
let size_now : @signals.Signal[Int] = @signals.signal(1)

///|
/// A line's width in points by its size; a mosaic's square; words' size.
fn line_pt(size : Int) -> Double {
  match size {
    0 => 2.0
    1 => 3.5
    _ => 6.0
  }
}

///|
fn mosaic_pt(size : Int) -> Double {
  match size {
    0 => 6.0
    1 => 10.0
    _ => 16.0
  }
}

///|
fn words_pt(size : Int) -> Double {
  match size {
    0 => 14.0
    1 => 18.0
    _ => 26.0
  }
}

///|
fn number_pt(size : Int) -> Double {
  match size {
    0 => 20.0
    1 => 26.0
    _ => 34.0
  }
}

///|
fn reset_marks() -> Unit {
  marks.set([])
  draft.set(None)
  undone.val = []
  done_before.val = []
}

///|
/// A mark added (what was before kept to undo it).
fn add_mark(m : Mark) -> Unit {
  done_before.val.push(marks.untracked())
  undone.val = []
  let next = marks.untracked().copy()
  next.push(m)
  marks.set(next)
}

///|
/// The marks as they were before the last change.
fn undo() -> Bool {
  guard done_before.val.pop() is Some(before) else { return false }
  undone.val.push(marks.untracked())
  marks.set(before)
  true
}

///|
fn redo() -> Bool {
  guard undone.val.pop() is Some(after) else { return false }
  done_before.val.push(marks.untracked())
  marks.set(after)
  true
}

///|
fn new_mark(t : Tool, pts : Array[(Double, Double)]) -> Mark {
  mark_ids.val += 1
  let n = if t == Number {
    let mut most = 0
    for m in marks.untracked() {
      if m.tool == Number && m.n > most {
        most = m.n
      }
    }
    most + 1
  } else {
    0
  }
  {
    id: mark_ids.val,
    tool: t,
    pts,
    color: color_now.untracked(),
    size: size_now.untracked(),
    n,
    words: "",
  }
}

///|
/// A mark that is too small to keep (a click where a drag was meant).
fn too_small(m : Mark) -> Bool {
  match m.tool {
    Box | Oval | Mosaic | Arrow => {
      let (x0, y0) = m.pts[0]
      let (x1, y1) = m.pts[m.pts.length() - 1]
      (x1 - x0).abs() < 3.0 && (y1 - y0).abs() < 3.0
    }
    Pen => m.pts.length() < 2
    _ => false
  }
}

// ---- drawn ----

///|
/// A stroked path in `c`, `w` wide, as a picture's layer.
fn stroke_layer(d : String, c : Int64, w : Double) -> @pixels.VectorPath {
  { d, fill: 0L, stroke: c, width: w, even_odd: false, sx: 1.0, sy: 1.0, tx: 0.0, ty: 0.0 }
}

///|
fn fill_layer(d : String, c : Int64, even_odd? : Bool = false) -> @pixels.VectorPath {
  { d, fill: c, stroke: 0L, width: 0.0, even_odd, sx: 1.0, sy: 1.0, tx: 0.0, ty: 0.0 }
}

///|
fn rect_path(x : Double, y : Double, w : Double, h : Double) -> String {
  "M\{num(x)} \{num(y)}h\{num(w)}v\{num(h)}h\{num(-w)}z"
}

///|
/// An ellipse in (x, y, w, h) as two arcs.
fn oval_path(x : Double, y : Double, w : Double, h : Double) -> String {
  let rx = w / 2.0
  let ry = h / 2.0
  "M\{num(x)} \{num(y + ry)}a\{num(rx)} \{num(ry)} 0 1 0 \{num(w)} 0a\{num(rx)} \{num(ry)} 0 1 0 \{num(-w)} 0z"
}

///|
/// A circle about (cx, cy).
fn circle_path(cx : Double, cy : Double, r : Double) -> String {
  oval_path(cx - r, cy - r, r * 2.0, r * 2.0)
}

///|
/// The layers that draw mark `m` in the monitor's pixels, `k` of them a point.
fn mark_layers(m : Mark, k : Double) -> Array[@pixels.VectorPath] {
  let w = line_pt(m.size) * k
  match m.tool {
    Box => {
      let (x0, y0) = m.pts[0]
      let (x1, y1) = m.pts[m.pts.length() - 1]
      let x = dmin(x0, x1)
      let y = dmin(y0, y1)
      [stroke_layer(rect_path(x, y, (x1 - x0).abs(), (y1 - y0).abs()), m.color, w)]
    }
    Oval => {
      let (x0, y0) = m.pts[0]
      let (x1, y1) = m.pts[m.pts.length() - 1]
      [stroke_layer(oval_path(dmin(x0, x1), dmin(y0, y1), (x1 - x0).abs(), (y1 - y0).abs()), m.color, w)]
    }
    Arrow => [fill_layer(arrow_path(m.pts[0], m.pts[m.pts.length() - 1], w), m.color)]
    Pen => {
      let sb = StringBuilder()
      for i, p in m.pts {
        sb.write_string(if i == 0 { "M" } else { "L" })
        sb.write_string(num(p.0))
        sb.write_char(' ')
        sb.write_string(num(p.1))
      }
      // (round ends: a dot at each, as wide as the line)
      let (ax, ay) = m.pts[0]
      let (bx, by) = m.pts[m.pts.length() - 1]
      [
        stroke_layer(sb.to_string(), m.color, w),
        fill_layer(circle_path(ax, ay, w / 2.0) + circle_path(bx, by, w / 2.0), m.color),
      ]
    }
    Number => {
      let (cx, cy) = m.pts[0]
      let r = number_pt(m.size) * k / 2.0
      [
        fill_layer(circle_path(cx, cy, r + k), 0xFFFFFFFFL),
        fill_layer(circle_path(cx, cy, r), m.color),
      ]
    }
    Mosaic => mosaic_layers(m, k)
    Move | Words => []
  }
}

///|
/// An arrow from `a` to `b`, its line `w` wide tapering from its tail, its head a triangle: one filled outline.
fn arrow_path(a : (Double, Double), b : (Double, Double), w : Double) -> String {
  let (ax, ay) = a
  let (bx, by) = b
  let dx = bx - ax
  let dy = by - ay
  let len = (dx * dx + dy * dy).sqrt()
  if len < 0.5 {
    return ""
  }
  let ux = dx / len
  let uy = dy / len
  // (across it)
  let nx = -uy
  let ny = ux
  let head = dmin(len * 0.6, w * 3.2 + 8.0)
  let head_w = head * 0.62
  let neck = head * 0.78
  let tail = w * 0.35
  let shaft = w * 0.6
  let hx = bx - ux * neck
  let hy = by - uy * neck
  let pts = [
    (ax + nx * tail, ay + ny * tail),
    (hx + nx * shaft, hy + ny * shaft),
    (bx - ux * head + nx * head_w, by - uy * head + ny * head_w),
    (bx, by),
    (bx - ux * head - nx * head_w, by - uy * head - ny * head_w),
    (hx - nx * shaft, hy - ny * shaft),
    (ax - nx * tail, ay - ny * tail),
  ]
  let sb = StringBuilder()
  for i, p in pts {
    sb.write_string(if i == 0 { "M" } else { "L" })
    sb.write_string(num(p.0))
    sb.write_char(' ')
    sb.write_string(num(p.1))
  }
  sb.write_string("z")
  sb.to_string()
}

///|
/// A mosaic over the rectangle between its two points: squares `mosaic_pt` points across, each the mean colour of the
/// picture under it; a square's run of one colour along a row drawn as one.
fn mosaic_layers(m : Mark, k : Double) -> Array[@pixels.VectorPath] {
  let (x0, y0) = m.pts[0]
  let (x1, y1) = m.pts[m.pts.length() - 1]
  let r = rect_between(x0.round().to_int(), y0.round().to_int(), x1.round().to_int(), y1.round().to_int()).within(
    mon.val.w,
    mon.val.h,
  )
  guard r is Some(r) else { return [] }
  let cell = dmax(2.0, (mosaic_pt(m.size) * k).round()).to_int()
  // (squares on the monitor's grid of them, so one dragged further keeps the squares it had)
  let gx0 = r.x / cell
  let gy0 = r.y / cell
  let gx1 = (r.right() + cell - 1) / cell
  let gy1 = (r.bottom() + cell - 1) / cell
  let by_color : Map[Int, StringBuilder] = Map([])
  for gy in gy0..<gy1 {
    let mut run_color = -1
    let mut run_x = 0
    let mut run_n = 0
    let cy = gy * cell
    let ch = clampi(r.bottom(), 0, mon.val.h) - cy
    let top = clampi(cy, r.y, r.bottom())
    let bottom = clampi(cy + cell, r.y, r.bottom())
    let flush = fn(c : Int, x : Int, n : Int) {
      if c >= 0 && n > 0 {
        let sb = match by_color.get(c) {
          Some(sb) => sb
          None => {
            let sb = StringBuilder()
            by_color[c] = sb
            sb
          }
        }
        let left = clampi(x, r.x, r.right())
        let right = clampi(x + n * cell, r.x, r.right())
        sb.write_string(rect_path(left.to_double(), top.to_double(), (right - left).to_double(), (bottom - top).to_double()))
      }
    }
    ignore(ch)
    for gx in gx0..<gx1 {
      let c = mean_color(gx * cell, cy, cell)
      if c == run_color {
        run_n += 1
      } else {
        flush(run_color, run_x, run_n)
        run_color = c
        run_x = gx * cell
        run_n = 1
      }
    }
    flush(run_color, run_x, run_n)
  }
  let out : Array[@pixels.VectorPath] = []
  for c, sb in by_color {
    out.push(fill_layer(sb.to_string(), (c.to_int64() << 8) | 0xFFL))
  }
  out
}

///|
/// The mean colour (0xRRGGBB) of the `cell` square at (x, y) of the picture taken (read where the native side keeps it).
fn mean_color(x : Int, y : Int, cell : Int) -> Int {
  ps_mean(x, y, cell)
}

///|
test "arrow path closes" {
  let d = arrow_path((0.0, 0.0), (100.0, 0.0), 4.0)
  assert_true(d.has_prefix("M"))
  assert_true(d.has_suffix("z"))
  assert_eq(arrow_path((0.0, 0.0), (0.0, 0.0), 4.0), "")
}
