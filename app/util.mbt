// Small things the rest is written with: numbers kept in a range, colours mixed, rectangles of the screen's pixels.

///|
fn clamp(v : Double, lo : Double, hi : Double) -> Double {
  if hi < lo {
    lo
  } else if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn clampi(v : Int, lo : Int, hi : Int) -> Int {
  if hi < lo {
    lo
  } else if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn dmin(a : Double, b : Double) -> Double {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn dmax(a : Double, b : Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}

///|
/// Colour `a` (RGBA) `k` of the way to `b`.
fn mix(a : Int64, b : Int64, k : Double) -> Int64 {
  let k = clamp(k, 0.0, 1.0)
  let ch = fn(c : Int64, s : Int) -> Double { ((c >> s) & 0xFFL).to_double() }
  let one = fn(s : Int) -> Int64 {
    let v = ch(a, s) + (ch(b, s) - ch(a, s)) * k
    (v.round().to_int64() & 0xFFL) << s
  }
  one(24) | one(16) | one(8) | one(0)
}

///|
/// A rectangle of the screen's pixels (x, y its top left), whole pixels.
#derive(Eq, Debug)
struct Rect {
  x : Int
  y : Int
  w : Int
  h : Int
}

///|
fn Rect::right(self : Rect) -> Int {
  self.x + self.w
}

///|
fn Rect::bottom(self : Rect) -> Int {
  self.y + self.h
}

///|
fn Rect::contains(self : Rect, x : Double, y : Double) -> Bool {
  x >= self.x.to_double() &&
  x < self.right().to_double() &&
  y >= self.y.to_double() &&
  y < self.bottom().to_double()
}

///|
/// The rectangle between two corners, whatever their order.
fn rect_between(x0 : Int, y0 : Int, x1 : Int, y1 : Int) -> Rect {
  let x = if x0 < x1 { x0 } else { x1 }
  let y = if y0 < y1 { y0 } else { y1 }
  { x, y, w: (x1 - x0).abs(), h: (y1 - y0).abs() }
}

///|
/// What of `r` is within `w` by `h` (None: nothing).
fn Rect::within(self : Rect, w : Int, h : Int) -> Rect? {
  let x0 = clampi(self.x, 0, w)
  let y0 = clampi(self.y, 0, h)
  let x1 = clampi(self.right(), 0, w)
  let y1 = clampi(self.bottom(), 0, h)
  if x1 - x0 <= 0 || y1 - y0 <= 0 {
    None
  } else {
    Some({ x: x0, y: y0, w: x1 - x0, h: y1 - y0 })
  }
}

///|
/// A number in a path's words: at most two decimals, no trailing zeros.
fn num(v : Double) -> String {
  let r = (v * 100.0).round() / 100.0
  let i = r.to_int()
  if i.to_double() == r {
    i.to_string()
  } else {
    r.to_string()
  }
}

///|
/// Superellipse corner parameters `(rr, c)` matching `mbui`'s smooth corners (`superellipse(1.5)`, `smooth_scale = 1.25`):
/// `rr` is how far along each edge the corner curve reaches from the vertex, and `c = rr * (1 - kappa)` is the distance
/// from the corner vertex to each cubic Bézier control point. Smoothly degrades to a circular arc (`kappa = 0.55228475`)
/// when `r` approaches half the shorter side (`room`).
fn superellipse_params(w : Double, h : Double, r : Double) -> (Double, Double) {
  let room = dmin(w, h) / 2.0
  let rc = clamp(r, 0.0, room)
  if rc <= 0.0 {
    return (0.0, 0.0)
  }
  let s = clamp((room - rc) / (0.25 * rc), 0.0, 1.0)
  let rr = dmin(rc * (1.0 + 0.25 * s), room)
  let kappa = 0.55228475 + (0.7621 - 0.55228475) * s
  (rr, rr * (1.0 - kappa))
}

///|
/// A rectangle with superellipse corners (`r` each, matching `mbui`'s smooth corners) as an SVG path.
fn superellipse_rect_path(x : Double, y : Double, w : Double, h : Double, r : Double) -> String {
  if w <= 0.0 || h <= 0.0 {
    return ""
  }
  let (rr, c) = superellipse_params(w, h, r)
  if rr <= 0.01 {
    return rect_path(x, y, w, h)
  }
  let x1 = x + w
  let y1 = y + h
  "M\{num(x + rr)} \{num(y)}H\{num(x1 - rr)}" +
  "C\{num(x1 - c)} \{num(y)} \{num(x1)} \{num(y + c)} \{num(x1)} \{num(y + rr)}" +
  "V\{num(y1 - rr)}" +
  "C\{num(x1)} \{num(y1 - c)} \{num(x1 - c)} \{num(y1)} \{num(x1 - rr)} \{num(y1)}" +
  "H\{num(x + rr)}" +
  "C\{num(x + c)} \{num(y1)} \{num(x)} \{num(y1 - c)} \{num(x)} \{num(y1 - rr)}" +
  "V\{num(y + rr)}" +
  "C\{num(x)} \{num(y + c)} \{num(x + c)} \{num(y)} \{num(x + rr)} \{num(y)}Z"
}

///|
test "rect_between and within" {
  let r = rect_between(10, 20, 4, 2)
  assert_eq(r, { x: 4, y: 2, w: 6, h: 18 })
  assert_eq({ x: -5, y: 5, w: 20, h: 10 }.within(10, 10), Some({ x: 0, y: 5, w: 10, h: 5 }))
  assert_eq({ x: 20, y: 5, w: 20, h: 10 }.within(10, 10), None)
}

///|
test "mix and num" {
  assert_eq(mix(0x000000FFL, 0xFFFFFFFFL, 0.5), 0x808080FFL)
  assert_eq(num(1.0), "1")
  assert_eq(num(1.256), "1.26")
}

///|
test "superellipse_params and superellipse_rect_path" {
  let (rr, c) = superellipse_params(100.0, 60.0, 12.0)
  assert_eq(num(rr), "15")
  assert_true(c > 3.5 && c < 3.6)
  let p = superellipse_rect_path(0.0, 0.0, 100.0, 60.0, 12.0)
  assert_true(p.has_prefix("M15 0H85C"))
  assert_true(p.has_suffix("Z"))
}
