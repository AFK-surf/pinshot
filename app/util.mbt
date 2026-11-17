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
/// `c` (RGBA) at alpha `alpha` (0..255).
fn with_alpha(c : Int64, alpha : Int) -> Int64 {
  (c & 0xFFFFFF00L) | (alpha.to_int64() & 0xFFL)
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
