// The part as the overlay shows it, on its way to where it is (the user, 2026-11-20: 「各个地方感觉可以加一下
// transition，比如capture选区变化时」): the window under the pointer, a window clicked, a part nudged by the keys, and the
// background turned on or off or its room changed, each go there by mbui's move spring from where it shows then; what
// the hand drags (a part drawn, moved or resized) follows the hand at once, and a part that comes from none is there at
// once. The veil, the frame, the handles, the size's label and the bar are drawn where it shows; what a press finds, and
// what is copied, is where it is.

///|
let shown_x : @motion.Way = @motion.Way::new(0.0)

///|
let shown_y : @motion.Way = @motion.Way::new(0.0)

///|
let shown_w : @motion.Way = @motion.Way::new(0.0)

///|
let shown_h : @motion.Way = @motion.Way::new(0.0)

///|
/// The room round the part where it is laid on a background (pixels; 0 none).
let shown_room : @motion.Way = @motion.Way::new(0.0)

///|
/// How clear the background the part is laid on shows (0 to 1): it comes in as it is turned on.
let beauty_fade : @motion.Way = @motion.Way::new(1.0)

///|
/// Whether a part showed as it last changed (a part coming from none is there at once).
let shown_had : Ref[Bool] = Ref(false)

///|
/// The ways set as the part, or the background's room, change: at the moment of their cause (`stage`'s).
fn shown_follow(stage : @view.View) -> Unit {
  stage.reacts(fn() { (clear_part(), beauty_frame()) }, fn(now) {
    let (part, frame) = now
    let at = stage.cause_at()
    match part {
      None => {
        shown_had.val = false
        shown_room.put(0.0)
      }
      Some(r) => {
        let held = match hand.untracked() {
          Drawing(_, _) | Moving(_, _, _) | Sizing(_, _, _) => true
          _ => false
        }
        let at_once = !shown_had.val || held
        for wv in [(shown_x, r.x), (shown_y, r.y), (shown_w, r.w), (shown_h, r.h)] {
          let (way, v) = wv
          if at_once {
            way.put(v.to_double())
          } else {
            way.go(v.to_double(), @motion.move_spring, at~)
          }
        }
        let room = match frame {
          Some(f) => (r.x - f.x).to_double()
          None => 0.0
        }
        if shown_had.val {
          shown_room.go(room, @motion.move_spring, at~)
        } else {
          shown_room.put(room)
        }
        shown_had.val = true
      }
    }
  })
}

///|
/// The part as node `n` draws it now (monitor pixels), None where none shows.
fn shown_part(n : @view.View) -> Rect? {
  guard clear_part() is Some(_) else { return None }
  let x = shown_x.shown_on(n).round().to_int()
  let y = shown_y.shown_on(n).round().to_int()
  let w = shown_w.shown_on(n).round().to_int()
  let h = shown_h.shown_on(n).round().to_int()
  Some({ x, y, w: if w < 1 { 1 } else { w }, h: if h < 1 { 1 } else { h } })
}

///|
/// The part and the room round it as node `n` draws them, where it is laid on a background (or the room is on its way
/// back to none); else None.
fn shown_frame(n : @view.View) -> Rect? {
  guard shown_part(n) is Some(r) else { return None }
  let p = shown_room.shown_on(n).round().to_int()
  if p <= 0 {
    return None
  }
  Some({ x: r.x - p, y: r.y - p, w: r.w + 2 * p, h: r.h + 2 * p })
}

///|
/// The picture as it will be copied, as node `n` draws it: the frame, else the part.
fn shown_whole(n : @view.View) -> Rect? {
  match shown_frame(n) {
    Some(f) => Some(f)
    None => shown_part(n)
  }
}
