// Core state and data model for PinShot (100% cross-platform MoonBit).

///|
#derive(Eq)
enum Tool {
  Select
  Rect
  Ellipse
  Arrow
  Pen
  Step
  Mosaic
}

///|
#derive(Eq)
struct BoxRect {
  x : Double
  y : Double
  w : Double
  h : Double
}

///|
#derive(Eq)
struct Annotation {
  kind : Tool
  x0 : Double
  y0 : Double
  x1 : Double
  y1 : Double
  pts : Array[(Double, Double)]
  color : Int64
  stroke : Double
  step_num : Int
}

///|
fn clamp(v : Double, lo : Double, hi : Double) -> Double {
  @cmp.maximum(lo, @cmp.minimum(hi, v))
}

///|
fn parse_int_or(s : String, fallback : Int) -> Int {
  let mut neg = false
  let mut i = 0
  let n = s.length()
  if n == 0 {
    return fallback
  }
  if s[0] == '-' {
    neg = true
    i = 1
  }
  let mut v = 0
  let mut any = false
  while i < n {
    let ch = s[i].to_int()
    if ch >= '0'.to_int() && ch <= '9'.to_int() {
      v = v * 10 + (ch - '0'.to_int())
      any = true
    } else {
      break
    }
    i += 1
  }
  if !any {
    fallback
  } else if neg {
    -v
  } else {
    v
  }
}

///|
fn parse_double_or(s : String, fallback : Double) -> Double {
  let mut neg = false
  let mut i = 0
  let n = s.length()
  if n == 0 {
    return fallback
  }
  if s[0] == '-' {
    neg = true
    i = 1
  }
  let mut whole = 0.0
  let mut frac = 0.0
  let mut div = 1.0
  let mut in_frac = false
  let mut any = false
  while i < n {
    let ch = s[i].to_int()
    if ch == '.'.to_int() && !in_frac {
      in_frac = true
    } else if ch >= '0'.to_int() && ch <= '9'.to_int() {
      let d = (ch - '0'.to_int()).to_double()
      if in_frac {
        div *= 10.0
        frac += d / div
      } else {
        whole = whole * 10.0 + d
      }
      any = true
    } else {
      break
    }
    i += 1
  }
  if !any {
    fallback
  } else {
    let r = whole + frac
    if neg { -r } else { r }
  }
}

// ---- Screen capture & window list ----

///|
let mon_x : Ref[Int] = Ref(0)

///|
let mon_y : Ref[Int] = Ref(0)

///|
let mon_w : Ref[Int] = Ref(1920)

///|
let mon_h : Ref[Int] = Ref(1080)

///|
let mon_scale : Ref[Double] = Ref(1.0)

///|
let win_w : @signals.Signal[Double] = @signals.signal(1920.0, same=fn(a, b) { a == b })

///|
let win_h : @signals.Signal[Double] = @signals.signal(1080.0, same=fn(a, b) { a == b })

///|
let frozen_bmp : Ref[Bytes] = Ref(b"")

///|
let frozen_key : @signals.Signal[String] = @signals.signal("")

///|
let capture_seq : Ref[Int] = Ref(0)

///|
let detected_wins : Array[BoxRect] = []

// ---- Selection & interaction ----

///|
let sel : @signals.Signal[BoxRect?] = @signals.signal(None, same=fn(a, b) { a == b })

///|
let hover_win : @signals.Signal[BoxRect?] = @signals.signal(None, same=fn(a, b) { a == b })

///|
let current_tool : @signals.Signal[Tool] = @signals.signal(Select, same=fn(a, b) { a == b })

///|
let current_color : @signals.Signal[Int64] = @signals.signal(0xEF4444FFL)

///|
let current_stroke : @signals.Signal[Double] = @signals.signal(3.0, same=fn(a, b) { a == b })

///|
let annotations : @signals.Signal[Array[Annotation]] = @signals.signal([], same=fn(a, b) { a == b })

///|
let redo_stack : Array[Annotation] = []

///|
let active_ann : @signals.Signal[Annotation?] = @signals.signal(None, same=fn(a, b) { a == b })

///|
let step_counter : Ref[Int] = Ref(1)

///|
let drag_kind : Ref[Int] = Ref(0) // 0 none, 1 new_sel, 2 move_sel, 3..10 handles, 11 draw_ann

///|
let drag_x0 : Ref[Double] = Ref(0.0)

///|
let drag_y0 : Ref[Double] = Ref(0.0)

///|
let drag_sel0 : Ref[BoxRect] = Ref({ x: 0.0, y: 0.0, w: 0.0, h: 0.0 })

///|
let pointer_pos : @signals.Signal[(Double, Double)] = @signals.signal((0.0, 0.0), same=fn(a, b) { a == b })

///|
let overlay_visible : @signals.Signal[Bool] = @signals.signal(false)

///|
fn reset_capture_state() -> Unit {
  sel.set(None)
  hover_win.set(None)
  current_tool.set(Select)
  annotations.set([])
  redo_stack.clear()
  active_ann.set(None)
  step_counter.val = 1
  drag_kind.val = 0
}

///|
fn start_capture() -> Bool {
  if ps_capture_screen() == 0 {
    return false
  }
  let info = @utf8.decode_lossy(ps_capture_info()[:])
  let parts = info.split(",").map(fn(s) { s.to_owned() }).to_array()
  if parts.length() < 5 {
    return false
  }
  mon_x.val = parse_int_or(parts[0], 0)
  mon_y.val = parse_int_or(parts[1], 0)
  mon_w.val = parse_int_or(parts[2], 1920)
  mon_h.val = parse_int_or(parts[3], 1080)
  mon_scale.val = @cmp.maximum(1.0, parse_double_or(parts[4], 1.0))
  win_w.set(mon_w.val.to_double() / mon_scale.val)
  win_h.set(mon_h.val.to_double() / mon_scale.val)

  let bmp = ps_capture_bmp()
  if bmp.length() < 54 {
    return false
  }
  frozen_bmp.val = bmp
  capture_seq.val += 1
  let key = "frozen-\{capture_seq.val}"
  @ui.add_image(key, bmp)
  frozen_key.set(key)

  detected_wins.clear()
  let wins_txt = @utf8.decode_lossy(ps_enum_windows()[:])
  let sc = mon_scale.val
  for line in wins_txt.split("\n") {
    let l = line.to_owned().trim().to_owned()
    if l == "" {
      continue
    }
    let ps = l.split(",").map(fn(s) { s.to_owned() }).to_array()
    if ps.length() >= 4 {
      detected_wins.push({
        x: parse_int_or(ps[0], 0).to_double() / sc,
        y: parse_int_or(ps[1], 0).to_double() / sc,
        w: parse_int_or(ps[2], 0).to_double() / sc,
        h: parse_int_or(ps[3], 0).to_double() / sc,
      })
    }
  }
  reset_capture_state()
  true
}

///|
fn window_at(x : Double, y : Double) -> BoxRect? {
  for r in detected_wins {
    if x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h {
      return Some(r)
    }
  }
  None
}

///|
fn undo_annotation() -> Unit {
  let list = annotations.untracked().copy()
  if list.is_empty() {
    return
  }
  let last = list.pop().unwrap()
  redo_stack.push(last)
  if last.kind == Step && step_counter.val > 1 {
    step_counter.val -= 1
  }
  annotations.set(list)
}

///|
fn redo_annotation() -> Unit {
  if redo_stack.is_empty() {
    return
  }
  let item = redo_stack.pop().unwrap()
  let list = annotations.untracked().copy()
  list.push(item)
  if item.kind == Step {
    step_counter.val += 1
  }
  annotations.set(list)
}
