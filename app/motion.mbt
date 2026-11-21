// Shared GPU-composited motion primitives for PinShot (all fast 100-160ms curves, zero Flex relayout):
// - mix_rgba: smooth per-channel RGBA interpolation for hovers, switches, and state transitions
// - smooth_hover / tactile_press: 110ms ease-out hover alpha + subtle micro-sink press spring
// - pop_presence / enter_reveal: crisp fade + micro-rise + 0.97 scale entrance/exit
// - sliding_thumb: zero-relayout underlay pill gliding cleanly beneath sibling labels in both directions
// - rolling_label: odometer-style per-character rolling tabular readout (@motion.rolling_slots_node)

///|
/// Crisp ease-out glide for segmented thumbs & sidebar indicators (fast 150ms, zero mushy tail).
let pill_glide : @motion.Spec = @motion.tween(150.0, ease=Out)

///|
/// Smooth per-channel RGBA interpolation between 0xRRGGBBAA colors (`t` clamped to 0..1).
fn mix_rgba(a : Int64, b : Int64, t : Double) -> Int64 {
  let k = clamp(t, 0.0, 1.0)
  if k <= 0.001 {
    return a
  }
  if k >= 0.999 {
    return b
  }
  let ch = fn(shift : Int) -> Int64 {
    let ca = ((a >> shift) & 0xFFL).to_int().to_double()
    let cb = ((b >> shift) & 0xFFL).to_int().to_double()
    clampi((ca + (cb - ca) * k + 0.5).to_int(), 0, 255).to_int64() << shift
  }
  ch(24) | ch(16) | ch(8) | ch(0)
}

///|
/// Smooth 0..1 hover progress on `v` (110ms ease-out by default).
fn smooth_hover(v : @view.View, live? : () -> Bool = fn() { true }, ms? : Double = 110.0) -> () -> Double {
  @motion.hover_fade(v, fn() { live() && v.pointed() }, duration_ms=ms)
}

///|
/// Subtle tactile press micro-sink + spring-back on `v` (zero relayout via View::scale).
fn tactile_press(v : @view.View, live? : () -> Bool = fn() { true }, sink_px? : Double = 1.2) -> Unit {
  @motion.press_feel(v, live~, sink_px~, sink_most=0.032, hovers=false) |> ignore
}

///|
/// Enter + exit presence transition on `v` (pair with parent.show(..., leave=leave_ms)).
fn pop_presence(
  v : @view.View,
  enter_ms? : Double = 140.0,
  leave_ms? : Double = 100.0,
  dy? : Double = 4.0,
  from_scale? : Double = 0.97,
) -> Unit {
  let p = @motion.presence_in(
    v,
    @motion.tween(enter_ms, ease=Out),
    exit=@motion.tween(leave_ms, ease=Leave),
    carries=true,
  )
  v.alpha(By(p)) |> ignore
  if from_scale != 1.0 {
    v.scale(By(fn() { from_scale + (1.0 - from_scale) * p() })) |> ignore
  }
  if dy != 0.0 {
    v.drawn_off(By(fn() { (0.0, dy * (1.0 - p())) })) |> ignore
  }
}

///|
/// Crisp downward drawer unfold for 2nd/3rd toolbar rows: smoothly expands height `0 -> full_h` (pushing lower rows
/// down naturally), clips only while animating so settled shadows stay intact, and slides the bar down from beneath its parent.
fn dropdown_unfold(
  slot : @view.View,
  full_h : Double,
  build : (@view.View) -> Unit,
  enter_ms? : Double = 165.0,
  leave_ms? : Double = 115.0,
) -> Unit {
  let p = @motion.presence_in(
    slot,
    @motion.tween(enter_ms, ease=Out),
    exit=@motion.tween(leave_ms, ease=Leave),
    carries=true,
  )
  slot
  .height(By(fn() { Some(full_h * p()) }))
  .shrink(Is(0.0))
  .clips(By(fn() { p() < 0.995 }))
  .lines_up(Is(Some(Start)))
  |> ignore
  slot.box(fn(panel) {
    panel
    .shrink(Is(0.0))
    .alpha(By(p))
    .drawn_off(By(fn() { (0.0, -14.0 * (1.0 - p())) }))
    |> ignore
    build(panel)
  })
  |> ignore
}

///|
/// Enter-only fade + micro-rise + subtle scale (safe with `at_once=true` and auto-fitted windows).
fn enter_reveal(
  v : @view.View,
  ms? : Double = 145.0,
  dy? : Double = 4.0,
  from_scale? : Double = 0.975,
) -> Unit {
  let w = @motion.NodeWay::new(0.0)
  w.go_from(v, 0.0, 1.0, @motion.tween(ms, ease=Out))
  v.alpha(By(fn() { w.shown(v) })) |> ignore
  if from_scale != 1.0 {
    v.scale(By(fn() { from_scale + (1.0 - from_scale) * w.shown(v) })) |> ignore
  }
  if dy != 0.0 {
    v.drawn_off(By(fn() { (0.0, dy * (1.0 - w.shown(v))) })) |> ignore
  }
}

///|
/// Dedicated zero-relayout sliding pill underlay placed BEFORE sibling items inside `container`.
/// Call this first in `container`, then register each sibling's `@view.View` in `item_views[key] = b`.
/// The pill glides cleanly beneath every label in both directions and smoothly adapts to width changes.
fn sliding_thumb(
  container : @view.View,
  active_key : () -> Int,
  item_views : Map[Int, @view.View],
  radius : Double,
  ground : () -> Int64,
  edge? : () -> (Double, Int64) = fn() { (0.0, 0L) },
  spec? : @motion.Spec = pill_glide,
  extra_watch? : () -> Int = fn() { 0 },
) -> Unit {
  let wx = @motion.NodeWay::new(0.0)
  let wy = @motion.NodeWay::new(0.0)
  let ww = @motion.NodeWay::new(0.0)
  let wh = @motion.NodeWay::new(0.0)
  let placed = Ref(false)
  let last_key = Ref(-999999)
  let visible : @signals.Signal[Bool] = @signals.signal(false)
  let thumb_ref : Ref[@view.View?] = Ref(None)
  let pending_cancel : Ref[() -> Unit] = Ref(fn() {  })

  container.box(fn(th) {
    thumb_ref.val = Some(th)
    th
    .over(Is(true))
    .presses(Is(false))
    .points(Is(false))
    .width(Is(Some(0.0)))
    .height(Is(Some(0.0)))
    .radius(Is(radius))
    .ground(By(fn() { if visible.get() { ground() } else { 0L } }))
    .edge(By(fn() { if visible.get() { edge() } else { (0.0, 0L) } }))
    .ground_drawn(By(fn() {
      if visible.get() {
        { dx: wx.shown(th), dy: wy.shown(th), dw: ww.shown(th), dh: wh.shown(th), corners: None }
      } else {
        @view.ground_as_laid
      }
    }))
    |> ignore
  })
  |> ignore

  container.owns(fn() { (pending_cancel.val)() }) |> ignore

  container.reacts(fn() { (active_key(), extra_watch()) }, fn(st) {
    let (key, _) = st
    let at = container.cause_at()
    let key_changed = placed.val && key != last_key.val
    last_key.val = key
    (pending_cancel.val)()
    pending_cancel.val = container.at_moment(at, fn() {
      pending_cancel.val = fn() {  }
      guard thumb_ref.val is Some(th) && th.alive() else { return }
      match item_views.get(key) {
        Some(target) if target.alive() => {
          let (ox, oy, _, _) = th.laid_window_now()
          let (ix, iy, iw, ih) = target.laid_window_now()
          if iw <= 0.5 || ih <= 0.5 {
            visible.set(false)
            return
          }
          let dx = ix - ox
          let dy = iy - oy
          if !placed.val {
            wx.put(dx)
            wy.put(dy)
            ww.put(iw)
            wh.put(ih)
            placed.val = true
            visible.set(true)
          } else {
            let sp = if key_changed { spec } else { @motion.tween(110.0, ease=Out) }
            wx.go(th, dx, sp)
            wy.go(th, dy, sp)
            ww.go(th, iw, sp)
            wh.go(th, ih, sp)
            visible.set(true)
          }
        }
        _ => {
          visible.set(false)
          placed.val = false
        }
      }
    })
  })
}

///|
#derive(Eq)
priv struct RollTextState {
  words : String
  dir : Double
}

///|
/// Odometer-style rolling numeric readout using `words_plain` (zero Flex relayout via `View::moved_by`,
/// without pulling in `@ui.TextStyle` token tables).
fn rolling_label(
  parent : @view.View,
  value : () -> Double,
  format : (Double) -> String,
  size : Double,
  line : Double,
  weight : Int,
  ink : () -> Int64,
  rolls? : () -> Bool = fn() { true },
) -> Unit {
  let first = @signals.untracked(value)
  let st : @signals.Signal[RollTextState] = @signals.signal({ words: format(first), dir: 0.0 })
  let last = Ref(first)
  let look = { ..@view.words_plain, size, weight, line, wrap: false }
  parent.box(fn(v) {
    v.row(Is(true)).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore
    v.reacts(value, at_start=false, fn(n) {
      let dir = if n > last.val { 1.0 } else if n < last.val { -1.0 } else { 0.0 }
      last.val = n
      let w = format(n)
      if w != st.untracked().words {
        st.set({ words: w, dir })
      }
    })
    v.each(
      fn() {
        let n = @motion.rolling_chars(st.get().words).length()
        Array::makei(n, fn(i) { n - 1 - i })
      },
      fn(k) { k },
      fn(slot, place) {
        let char_now = fn() {
          let cs = @motion.rolling_chars(st.get().words)
          let i = cs.length() - 1 - place.untracked()
          if i >= 0 && i < cs.length() { cs[i].to_string() } else { "" }
        }
        let held = @signals.untracked(char_now)
        let shown : @signals.Signal[String] = @signals.signal(held)
        let gone : @signals.Signal[String] = @signals.signal("")
        let way_dir = Ref(1.0)
        let roll = @motion.NodeWay::new(1.0)
        slot.reacts(fn() { (char_now(), st.get().dir) }, at_start=false, fn(now) {
          let (c, d) = now
          if c == shown.untracked() {
            return
          }
          if !@signals.untracked(rolls) {
            gone.set("")
            shown.set(c)
            roll.put(1.0)
            return
          }
          gone.set(shown.untracked())
          shown.set(c)
          way_dir.val = if d < 0.0 { -1.0 } else { 1.0 }
          roll.go_from(slot, 0.0, 1.0, @motion.digit_spring)
        })
        let rolling = fn() { roll.goes(slot) }
        slot
        .clips(Is(true))
        .fades(By(fn() { if rolling() { (0.0, 3.0, 0.0, 3.0) } else { (0.0, 0.0, 0.0, 0.0) } }))
        |> ignore
        let ends = fn(_w : Double, _h : Double) {
          roll.target() |> ignore
          roll.end()
        }
        slot.box(fn(w) {
          w
          .words(By(fn() { shown.get() }), look~)
          .ink(By(ink))
          .moved_by(fn(_w, h, at) { (0.0, way_dir.val * h * (1.0 - dmin(1.0, roll.value_at(at)))) }, ends)
          |> ignore
        })
        |> ignore
        slot.show(fn() { rolling() && gone.get() != "" }, at_once=true, fn(o) {
          o.over(Is(true)) |> ignore
          o.box(fn(w) {
            w
            .words(By(fn() { gone.get() }), look~)
            .ink(By(ink))
            .moved_by(fn(_w, h, at) { (0.0, -way_dir.val * h * dmin(1.0, roll.value_at(at))) }, ends)
            |> ignore
          })
          |> ignore
        })
      },
      along_row=true,
    )
  })
  |> ignore
}
