// The overlay (window 0): the screen as it was when the shortcut was pressed, under a veil but for the part picked or
// the window the pointer is over; that part's frame, its handles and its size; the marks on it; the tool bar under it;
// a magnifier by the pointer while a part is being picked. Its whole tree is made once as the run starts and kept: a
// capture only changes what it reads.
//
// The hand (as PixPin's, which the user follows): over nothing picked, a click picks the window under the pointer and a
// drag picks what it drags out; on the part picked, a drag moves it (or, a tool chosen, draws a mark), its edges and
// corners resize it; a right click lets it go (with none, closes); a double click in it, Enter or Ctrl+C copies it;
// Esc closes.

///|
let overlay_root : Ref[@view.View?] = Ref(None)

///|
/// The moment of what is being done: the tree's clock.
fn now() -> Double {
  match overlay_root.val {
    Some(r) => r.cause_at()
    None => 0.0
  }
}

///|
/// The overlay's accent: the frame of what is picked, its handles.
let accent : Int64 = 0x2F9BFFFFL

///|
/// A point of the overlay (points) in the monitor's pixels.
fn to_px(x : Double, y : Double) -> (Double, Double) {
  let k = mon_scale.untracked()
  (clamp(x * k, 0.0, mon.val.w.to_double()), clamp(y * k, 0.0, mon.val.h.to_double()))
}

///|
/// The monitor's size in points.
fn mon_pt() -> (Double, Double) {
  let k = mon_scale.get()
  ignore(frozen_key.get())
  (mon.val.w.to_double() / k, mon.val.h.to_double() / k)
}

///|
/// Which handle of `r` (pixels) the point (pixels) is on: (hx, hy), -1 left/top, 1 right/bottom, 0 the middle; (0, 0)
/// inside it, None outside. 6 points each side of an edge.
fn handle_at(r : Rect, x : Double, y : Double) -> (Int, Int)? {
  let reach = 6.0 * mon_scale.untracked()
  let x0 = r.x.to_double()
  let y0 = r.y.to_double()
  let x1 = r.right().to_double()
  let y1 = r.bottom().to_double()
  if x < x0 - reach || x > x1 + reach || y < y0 - reach || y > y1 + reach {
    return None
  }
  let hx = if (x - x0).abs() <= reach { -1 } else if (x - x1).abs() <= reach { 1 } else { 0 }
  let hy = if (y - y0).abs() <= reach { -1 } else if (y - y1).abs() <= reach { 1 } else { 0 }
  if hx == 0 && hy == 0 && !r.contains(x, y) {
    return None
  }
  Some((hx, hy))
}

///|
fn side_cursor(side : (Int, Int)) -> @view.Cursor {
  match side {
    (0, 0) => Grab
    (0, _) => ResizeY
    (_, 0) => ResizeX
    (-1, -1) | (1, 1) => ResizeNWSE
    _ => ResizeNESW
  }
}

///|
/// The pointer's shape on the overlay.
fn overlay_cursor() -> @view.Cursor? {
  match hand.get() {
    Drawing(_, _) | Marking => return Some(Crosshair)
    Moving(_, _, _) | Dragging(_, _, _, _, _, -1, _) => return Some(Grabbing)
    Dragging(_, _, _, _, _, _, _) => return Some(Crosshair)
    Sizing(hx, hy, _) => return Some(side_cursor((hx, hy)))
    Free => ()
  }
  match sel.get() {
    None => Some(Crosshair)
    Some(r) => {
      let (x, y) = pointer_px.get()
      if selected_handle_at(x, y) is Some(_) {
        return Some(Crosshair)
      }
      match handle_at(r, x, y) {
        Some((0, 0)) =>
          if tool.get() == Move || mark_at(x, y, false) is Some(_) {
            Some(Grab)
          } else {
            Some(Crosshair)
          }
        Some(side) => Some(side_cursor(side))
        None => Some(Arrow)
      }
    }
  }
}

///|
/// What the veil leaves clear: the part picked, else the window the pointer is over.
fn clear_part() -> Rect? {
  match sel.get() {
    Some(r) => Some(r)
    None => window_under()
  }
}

///|
/// The veil, the frame of what is clear and, a part picked, its eight handles: one picture in the monitor's pixels.
fn chrome_picture() -> @pixels.Vector? {
  if !capturing.get() {
    return None
  }
  let w = mon.val.w.to_double()
  let h = mon.val.h.to_double()
  let k = mon_scale.get()
  let picked = sel.get() is Some(_)
  let layers : Array[@pixels.VectorPath] = []
  match clear_part() {
    Some(r) => {
      let (x, y, rw, rh) = (r.x.to_double(), r.y.to_double(), r.w.to_double(), r.h.to_double())
      // (the veil one path, the part a hole in it: no seam where two pieces would meet)
      layers.push(fill_layer(rect_path(0.0, 0.0, w, h) + rect_path(x, y, rw, rh), 0x00000078L, even_odd=true))
      let line = dmax(1.0, k.round())
      let half = line / 2.0
      layers.push(stroke_layer(rect_path(x + half, y + half, rw - line, rh - line), accent, line))
      if picked && hand.get() != Marking {
        let s = (6.0 * k).round()
        let hs = s / 2.0
        let mut dots = ""
        for hx in [0.0, 0.5, 1.0] {
          for hy in [0.0, 0.5, 1.0] {
            if hx == 0.5 && hy == 0.5 {
              continue
            }
            let cx = (x + rw * hx).round()
            let cy = (y + rh * hy).round()
            dots = dots + rect_path(cx - hs, cy - hs, s, s)
          }
        }
        layers.push(fill_layer(dots, 0xFFFFFFFFL))
        layers.push(stroke_layer(dots, accent, line))
      }
    }
    None => layers.push(fill_layer(rect_path(0.0, 0.0, w, h), 0x00000078L))
  }
  Some({ w, h, layers })
}

///|
/// The overlay's window made one of PinShot's own as its first frame is drawn (its window is there then): out of sight
/// till a capture, before anything can open one.
let overlay_owned : Ref[Bool] = Ref(false)

///|
fn overlay_first_frame() -> Unit {
  if overlay_owned.val || @ui.current_window_id() != 0 {
    return
  }
  overlay_owned.val = true
  ps_own(0, 1) |> ignore
  if !capturing.untracked() {
    ps_hide(0)
  }
  if started_with_settings.val {
    open_settings()
  } else if !capturing.untracked() {
    // (none when the person's own is open already: a shortcut pressed as the run started, shown as its first frame)
    // (one capture taken out of sight as it starts, all of it as one is (the screen taken, the overlay at the
    // monitor's size, the picture a texture, a frame drawn) and let go: the first the person takes is as quick as
    // any, not ~50 ms slower; what it held given back after, as any capture's)
    warming.val = true
    log("warm-up: asked")
    ps_capture_ask()
    // (let go however it went, should its frame never come: a capture asked for meanwhile waits on it)
    match overlay_root.val {
      Some(r) =>
        r.at_moment(now() + 2500.0, fn() {
          if warming.val && capturing.untracked() {
            log("warm-up: not drawn in 2.5 s, let go")
            close_capture()
          }
        }, later=true)
        |> ignore
      None => ()
    }
  }
}

///|
/// Whether the capture under way is the one taken as the run starts (never seen).
let warming : Ref[Bool] = Ref(false)

///|
/// The overlay's tree, made once.
fn overlay_window(root : @view.View) -> Unit {
  overlay_root.val = Some(root)
  root.tree.hand_over_presses(false)
  root.ground(Is(0x000000FFL)).keymap(Is(overlay_keys())) |> ignore
  overlay_actions(root)
  // (seen once its first frame with the picture is on the screen: the frame after the decode is told)
  root.reacts(fn() {
    let key = frozen_key.get()
    key != "" && root.image_ready(key, dmax(mon.val.w.to_double(), mon.val.h.to_double()))
  }, fn(ready) {
    if ready && capturing.untracked() && !overlay_seen.untracked() {
      root.at_moment(root.cause_at() + 1.0, fn() {
        if capturing.untracked() && warming.val {
          // (drawn whole once as if seen, its magnifier and its words too, still out of sight; then let go)
          overlay_seen.set(true)
          root.at_moment(root.cause_at() + 60.0, fn() { if warming.val { close_capture() } }, later=true) |> ignore
          return
        }
        if capturing.untracked() && !overlay_seen.untracked() {
          ps_cloak(0, 0)
          overlay_seen.set(true)
          said_shown()
        }
      }, later=true)
      |> ignore
    }
  })
  root.box(fn(stage) {
    stage
    .over(Is(true))
    .presses(Is(true))
    .cursor(By(overlay_cursor))
    .on_pointer_moved(fn() {
      match stage.pointer_here() {
        Some((x, y)) => pointer_px.set(to_px(x, y))
        None => ()
      }
    })
    .on_drag(fn(d) { stage_drag(d) })
    .on_menu(fn(_) { step_back() })
    |> ignore
    // the picture as it was taken, at its own pixels
    stage.box(fn(p) {
      p
      .over(Is(true))
      .image(By(fn() {
        let key = frozen_key.get()
        if key == "" {
          None
        } else {
          Some((key, "", dmax(mon.val.w.to_double(), mon.val.h.to_double()).to_int()))
        }
      }))
      .presses(Is(false))
      |> ignore
    })
    |> ignore
    marks_layer(stage, editing=true)
    // the veil, the frame, the handles
    stage.box(fn(c) { c.over(Is(true)).presses(Is(false)).picture(By(chrome_picture)) |> ignore }) |> ignore
    size_label(stage)
    toolbar(stage)
    magnifier(stage)
  })
  |> ignore
}

///|
/// The marks (those made, and the one being drawn), each its own node over all of the picture, in the monitor's
/// pixels: one made is drawn once, not again as the next is drawn. `editing`: the words being written too.
fn marks_layer(parent : @view.View, editing~ : Bool) -> Unit {
  parent.box(fn(layer) {
    layer.over(Is(true)) |> ignore
    layer.each(fn() { marks.get() }, fn(m) { m.id }, fn(row, m) {
      row.over(Is(true)).presses(Is(false)) |> ignore
      mark_node(row, @signals.untracked(fn() { m.get() }))
    }, at_once=true)
    layer.box(fn(d) {
      d.over(Is(true)).presses(Is(false)) |> ignore
      d.pick(fn() { draft.get() }, fn(b, m) {
        b.over(Is(true)) |> ignore
        match m {
          Some(m) => mark_node(b, m)
          None => ()
        }
      }, at_once=true)
    })
    |> ignore
    if editing {
      layer.box(fn(h) { h.over(Is(true)).presses(Is(false)).picture(By(picked_picture)) |> ignore }) |> ignore
      words_editor(layer)
    }
  })
  |> ignore
}

///|
/// One mark drawn in `b` (over all of the picture).
fn mark_node(b : @view.View, m : Mark) -> Unit {
  let k = @signals.untracked(fn() { mon_scale.get() })
  let w = mon.val.w.to_double()
  let h = mon.val.h.to_double()
  match m.tool {
    Words => words_mark(b, m, k)
    _ => {
      let layers = mark_layers(m, k)
      b.picture(Is(Some({ w, h, layers }))) |> ignore
      if m.tool == Number {
        let (cx, cy) = m.pts[0]
        let d = number_pt(m.size)
        b.box(fn(n) {
          n
          .width(Is(Some(d)))
          .height(Is(Some(d)))
          .offset(Is((cx / k - d / 2.0, cy / k - d / 2.0)))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          |> ignore
          n.box(fn(t) {
            t
            .words(Is(m.n.to_string()), look={
              ..@view.words_plain,
              size: d * 0.56,
              weight: 700,
              line: d * 0.7,
              wrap: false,
            })
            .ink(Is(if m.color == 0xFFFFFFFFL { 0x111214FFL } else { 0xFFFFFFFFL }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
      }
    }
  }
}

///|
/// Words written on the picture: at their place, in their colour and size, a dark edge round light words.
fn words_mark(b : @view.View, m : Mark, k : Double) -> Unit {
  let (x, y) = m.pts[0]
  let size = words_pt(m.size)
  b.box(fn(t) {
    t
    // (where the line typed in showed them: its frame 3 points before the place, 4 points in)
    .offset(Is((x / k + 1.0, y / k)))
    .words(Is(m.words), look={ ..@view.words_plain, size, weight: 400, line: (size * 1.3).round(), wrap: false })
    .ink(Is(m.color))
    |> ignore
  })
  |> ignore
}

///|
/// The part's size, over its top left corner (inside it where there is no room over it).
fn size_label(stage : @view.View) -> Unit {
  stage.box(fn(o) {
    o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
    o.box(fn(l) {
      l
      .row(Is(true))
      .height(Is(Some(22.0)))
      .padding(Is((7.0, 0.0, 7.0, 0.0)))
      .radius(Is(5.0))
      .ground(Is(0x17181BE6L))
      .lines_up(Is(Some(Middle)))
      .laid_nowhere(By(fn() { clear_part() is None }))
      .offset(By(fn() {
        let k = mon_scale.get()
        match clear_part() {
          Some(r) => {
            let x = r.x.to_double() / k
            let y = r.y.to_double() / k
            (x, if y >= 28.0 { y - 28.0 } else { y + 6.0 })
          }
          None => (0.0, 0.0)
        }
      }))
      |> ignore
      l.box(fn(t) {
        t
        .words(By(fn() {
          match clear_part() {
            Some(r) => "\{r.w} × \{r.h}"
            None => ""
          }
        }), look={ ..@view.words_plain, size: 12.0, weight: 500, line: 16.0, wrap: false })
        .ink(Is(0xEDEEF0FFL))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

// ---- the hand ----

///|
/// Where the last press went down (pixels), and whether it has moved 3 points from there.
let down_at : Ref[(Double, Double, Bool)] = Ref((0.0, 0.0, false))

///|
/// Whether the press under way put down words being written (it opens no new ones).
let words_put_down : Ref[Bool] = Ref(false)

///|
fn stage_drag(d : @view.Drag) -> Unit {
  let (x, y) = to_px(d.x, d.y)
  pointer_px.set((x, y))
  match d.kind {
    Down => press_down(x, y)
    Moved => {
      let (x0, y0, moved) = down_at.val
      let k = mon_scale.untracked()
      if !moved && ((x - x0).abs() >= 3.0 * k || (y - y0).abs() >= 3.0 * k) {
        down_at.val = (x0, y0, true)
      }
      press_moved(x, y)
    }
    Up => press_up(x, y)
    Off => drop_held()
  }
}

///|
/// What the hand holds let go of as it was: a mark being drawn called off, one dragged put back where it was.
fn drop_held() -> Unit {
  @signals.start_batch()
  if hand.untracked() is Dragging(_, _, _, before, _, _, _) {
    marks.set(before)
  }
  draft.set(None)
  hand.set(Free)
  @signals.end_batch()
}

///|
/// Mark `m` dragged by (`dx`, `dy`) pixels: a mosaic by whole squares (it keeps to their grid).
fn dragged(m : Mark, dx : Double, dy : Double) -> Mark {
  if m.tool == Mosaic {
    let cell = dmax(2.0, (mosaic_pt(m.size) * mon_scale.untracked()).round())
    moved_by(m, (dx / cell).round() * cell, (dy / cell).round() * cell)
  } else {
    moved_by(m, dx, dy)
  }
}

///|
/// Where mark `m` held by (hx, hy) (-1: whole) from (x0, y0) is with the pointer at (x, y): a line's or an arrow's end
/// kept straight with Shift held.
fn held_to(m : Mark, hx : Int, hy : Int, x0 : Double, y0 : Double, x : Double, y : Double) -> Mark {
  if hx < 0 {
    return dragged(m, x - x0, y - y0)
  }
  let (x, y) = if (m.tool == Line || m.tool == Arrow) && ps_shift_down() == 1 {
    let (ox, oy) = m.pts[if hx == 0 { m.pts.length() - 1 } else { 0 }]
    snap45(ox, oy, x, y)
  } else {
    (x, y)
  }
  reshaped(m, hx, hy, x, y)
}

///|
/// Which handle of the mark picked the point (pixels) is on: (its index, hx, hy).
fn selected_handle_at(x : Double, y : Double) -> (Int, Int, Int)? {
  guard selected.get() is Some(id) && mark_index(id) is Some(i) else { return None }
  let reach = 7.0 * mon_scale.untracked()
  for h in mark_handles(marks.untracked()[i]) {
    let (hx, hy, px, py) = h
    if (x - px).abs() <= reach && (y - py).abs() <= reach {
      return Some((i, hx, hy))
    }
  }
  None
}

///|
/// The mark at `i` taken up by the hand from (x, y): out of the marks while it is held, drawn as the draft, picked.
fn take_up(i : Int, x : Double, y : Double, hx : Int, hy : Int) -> Unit {
  let before = marks.untracked()
  let rest = before.copy()
  let m = rest.remove(i)
  @signals.start_batch()
  marks.set(rest)
  draft.set(Some(m))
  selected.set(Some(m.id))
  hand.set(Dragging(x, y, m, before, i, hx, hy))
  @signals.end_batch()
}

///|
fn press_down(x : Double, y : Double) -> Unit {
  down_at.val = (x, y, false)
  // (a press while words are written puts them down, and only that)
  words_put_down.val = false
  if words_open.untracked() is Some(_) {
    commit_words()
    words_put_down.val = true
  }
  // (a handle of the mark picked: that end or corner moved)
  if selected_handle_at(x, y) is Some((i, hx, hy)) {
    take_up(i, x, y, hx, hy)
    return
  }
  match sel.untracked() {
    None => hand.set(Drawing(x, y))
    Some(r) =>
      match handle_at(r, x, y) {
        Some((0, 0)) =>
          match mark_at(x, y, tool.untracked() == Move) {
            // (on a mark: it is picked and dragged, whatever tool is held)
            Some(i) => take_up(i, x, y, -1, -1)
            None => {
              selected.set(None)
          match tool.untracked() {
            Move => hand.set(Moving(x, y, r))
            Number | Words => hand.set(Marking)
            t => {
              hand.set(Marking)
              let start = if t == Mosaic {
                let cell = dmax(2.0, (mosaic_pt(size_now.untracked()) * mon_scale.untracked()).round())
                ((x / cell).floor() * cell, (y / cell).floor() * cell)
              } else {
                (x, y)
              }
              draft.set(Some(new_mark(t, [start, start])))
            }
          }
            }
          }
        Some((hx, hy)) => {
          selected.set(None)
          hand.set(Sizing(hx, hy, r))
        }
        // (outside it: a part dragged out anew, where nothing is marked yet)
        None => if marks.untracked().is_empty() { hand.set(Drawing(x, y)) }
      }
  }
}

///|
fn press_moved(x : Double, y : Double) -> Unit {
  let (_, _, moved) = down_at.val
  let w = mon.val.w
  let h = mon.val.h
  match hand.untracked() {
    Drawing(x0, y0) =>
      if moved {
        let r = rect_between(x0.round().to_int(), y0.round().to_int(), x.round().to_int(), y.round().to_int())
        sel.set(r.within(w, h))
      }
    Moving(x0, y0, r) => {
      let nx = clampi(r.x + (x - x0).round().to_int(), 0, w - r.w)
      let ny = clampi(r.y + (y - y0).round().to_int(), 0, h - r.h)
      sel.set(Some({ ..r, x: nx, y: ny }))
    }
    Sizing(hx, hy, r) => {
      let xi = x.round().to_int()
      let yi = y.round().to_int()
      let x0 = if hx < 0 { xi } else { r.x }
      let x1 = if hx > 0 { xi } else { r.right() }
      let y0 = if hy < 0 { yi } else { r.y }
      let y1 = if hy > 0 { yi } else { r.bottom() }
      match rect_between(x0, y0, x1, y1).within(w, h) {
        Some(n) if n.w >= 1 && n.h >= 1 => sel.set(Some(n))
        _ => ()
      }
    }
    Dragging(x0, y0, m, _, _, hx, hy) => if moved { draft.set(Some(held_to(m, hx, hy, x0, y0, x, y))) }
    Marking =>
      match draft.untracked() {
        Some(m) => {
          let (cx, cy) = clamp_to_sel(x, y)
          // (a mosaic's corner on its squares' grid: drawn again only as it crosses into another square)
          let (cx, cy) = if m.tool == Mosaic {
            let cell = dmax(2.0, (mosaic_pt(m.size) * mon_scale.untracked()).round())
            let snap = fn(v : Double, from : Double) {
              if v >= from {
                (v / cell).ceil() * cell
              } else {
                (v / cell).floor() * cell
              }
            }
            (snap(cx, m.pts[0].0), snap(cy, m.pts[0].1))
          } else {
            (cx, cy)
          }
          if m.tool == Mosaic && m.pts[m.pts.length() - 1] == (cx, cy) {
            return
          }
          // (a line or an arrow with Shift held: straight across, up and down, or at 45 degrees)
          let (cx, cy) = if (m.tool == Line || m.tool == Arrow) && ps_shift_down() == 1 {
            let (sx, sy) = snap45(m.pts[0].0, m.pts[0].1, cx, cy)
            clamp_to_sel(sx, sy)
          } else {
            (cx, cy)
          }
          let pts = if m.tool == Pen {
            let p = m.pts.copy()
            p.push((cx, cy))
            p
          } else {
            [m.pts[0], (cx, cy)]
          }
          draft.set(Some({ ..m, pts, }))
        }
        None => ()
      }
    Free => ()
  }
}

///|
/// A point kept within the part picked.
fn clamp_to_sel(x : Double, y : Double) -> (Double, Double) {
  match sel.untracked() {
    Some(r) =>
      (clamp(x, r.x.to_double(), r.right().to_double()), clamp(y, r.y.to_double(), r.bottom().to_double()))
    None => (x, y)
  }
}

///|
/// When and where (pixels) the last click was let go (a second soon after and near it: a double click).
let last_click : Ref[(Double, Double, Double)] = Ref((0.0, 0.0, 0.0))

///|
/// Whether the click let go at (x, y) is the second of two: as soon after the first as Windows' double click (500 ms)
/// and within 4 points of it.
fn second_click(x : Double, y : Double) -> Bool {
  let t = ps_now_ms()
  let (lt, lx, ly) = last_click.val
  let reach = 4.0 * mon_scale.untracked()
  if t - lt <= 500.0 && (x - lx).abs() <= reach && (y - ly).abs() <= reach {
    last_click.val = (0.0, 0.0, 0.0)
    true
  } else {
    last_click.val = (t, x, y)
    false
  }
}

///|
fn press_up(x : Double, y : Double) -> Unit {
  let (_, _, moved) = down_at.val
  // (a double click in the part copies it, whatever tool is held, but where a click puts a number or words down: as
  // PixPin's; the first of the two picks the window under it where nothing is picked yet)
  if moved {
    last_click.val = (0.0, 0.0, 0.0)
  } else if second_click(x, y) {
    let t = tool.untracked()
    match sel.untracked() {
      Some(r) if r.contains(x, y) && t != Number && t != Words && words_open.untracked() is None => {
        drop_held()
        copy_out()
        return
      }
      _ => ()
    }
  }
  match hand.untracked() {
    Drawing(_, _) =>
      if !moved {
        // (a click: the window under the pointer)
        sel.set(window_at(x, y))
      } else {
        match sel.untracked() {
          Some(r) if r.w < 2 || r.h < 2 => sel.set(None)
          _ => ()
        }
      }
    Dragging(x0, y0, m, before, i, hx, hy) => {
      @signals.start_batch()
      draft.set(None)
      // (put back where it was among the marks: moved, one step to undo; else as it was, picked, its colour and
      // thickness the bar's)
      marks.set(before)
      if moved {
        replace_mark(i, held_to(m, hx, hy, x0, y0, x, y))
      } else {
        color_now.set(m.color)
        size_now.set(m.size)
      }
      hand.set(Free)
      @signals.end_batch()
      return
    }
    Marking =>
      match tool.untracked() {
        Number => add_mark(new_mark(Number, [(x, y)]))
        Words => if !words_put_down.val { open_words(x, y) }
        _ =>
          match draft.untracked() {
            Some(m) => {
              draft.set(None)
              if !too_small(m) {
                add_mark(m)
              }
            }
            None => ()
          }
      }
    _ => ()
  }
  hand.set(Free)
}

///|
/// A right click: the mark being drawn called off, else the tool put down, else the part let go, else the capture
/// closed.
fn step_back() -> Unit {
  if words_open.untracked() is Some(_) {
    words_open.set(None)
  } else if draft.untracked() is Some(_) {
    drop_held()
  } else if selected.untracked() is Some(_) {
    selected.set(None)
  } else if sel.untracked() is Some(_) {
    @signals.start_batch()
    sel.set(None)
    reset_marks()
    tool.set(Move)
    @signals.end_batch()
  } else {
    close_capture()
  }
}

// ---- the keys ----

///|
fn overlay_keys() -> @view.Keymap {
  let k = fn(code : Int, action : String, mods : Int) -> @view.Binding {
    { keys: [{ code, mods }], action, when: Always }
  }
  let ch = fn(c : Char, action : String, mods : Int) { k(@ui.key_of_char(c), action, mods) }
  let ctrl = @ui.mod_ctrl
  let shift = @ui.mod_shift_key
  @view.Keymap::new([
    k(@ui.key_escape, "close", 0),
    k(@ui.key_code_delete, "delete", 0),
    k(@ui.key_code_backspace, "delete", 0),
    k(@ui.key_code_enter, "copy", 0),
    ch('c', "copy", ctrl),
    ch('s', "save", ctrl),
    ch('t', "pin", ctrl),
    ch('z', "undo", ctrl),
    ch('y', "redo", ctrl),
    ch('z', "redo", ctrl | shift),
    ch('c', "copy-color", 0),
    k(@ui.key_code_left, "left", 0),
    k(@ui.key_code_right, "right", 0),
    k(@ui.key_code_up, "up", 0),
    k(@ui.key_code_down, "down", 0),
    k(@ui.key_code_left, "left10", shift),
    k(@ui.key_code_right, "right10", shift),
    k(@ui.key_code_up, "up10", shift),
    k(@ui.key_code_down, "down10", shift),
  ])
}

///|
fn overlay_actions(root : @view.View) -> Unit {
  let on = fn(name : String, f : () -> Unit) {
    root.on_action(name, fn(_) {
      if !capturing.untracked() {
        return false
      }
      // (a key while words are written is theirs, but Escape, which lets them go)
      if words_open.untracked() is Some(_) && name != "close" {
        return false
      }
      f()
      true
    })
    |> ignore
  }
  on("close", fn() {
    if words_open.untracked() is Some(_) {
      commit_words()
    } else if selected.untracked() is Some(_) {
      selected.set(None)
    } else {
      close_capture()
    }
  })
  on("delete", fn() { delete_selected() |> ignore })
  on("copy", copy_out)
  on("save", save_out)
  on("pin", pin_out)
  on("undo", fn() { undo() |> ignore })
  on("redo", fn() { redo() |> ignore })
  on("copy-color", copy_color)
  for step in [(1, ""), (10, "10")] {
    let (n, s) = step
    // (the mark picked moved, else the part)
    let k = fn(dx : Int, dy : Int) {
      if !nudge_selected(dx.to_double(), dy.to_double()) {
        nudge(dx, dy)
      }
    }
    on("left" + s, fn() { k(-n, 0) })
    on("right" + s, fn() { k(n, 0) })
    on("up" + s, fn() { k(0, -n) })
    on("down" + s, fn() { k(0, n) })
  }
}

///|
/// The part moved by (dx, dy) pixels.
fn nudge(dx : Int, dy : Int) -> Unit {
  match sel.untracked() {
    Some(r) => {
      let m = mon.val
      sel.set(Some({ ..r, x: clampi(r.x + dx, 0, m.w - r.w), y: clampi(r.y + dy, 0, m.h - r.h) }))
    }
    None => ()
  }
}

///|
/// The colour under the pointer copied as #RRGGBB.
fn copy_color() -> Unit {
  let (x, y) = pointer_px.untracked()
  let c = pixel_at(x.to_int(), y.to_int())
  if c >= 0 {
    @hostapi.clipboard_set(hex6(c))
    close_capture()
  }
}

///|
fn hex6(c : Int) -> String {
  let digits = "0123456789ABCDEF"
  let sb = StringBuilder()
  sb.write_char('#')
  for i in 0..<6 {
    let v = (c >> ((5 - i) * 4)) & 0xF
    sb.write_char(digits[v].to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
/// The timings of a capture said in the log as it is seen: from the press to the screen taken, and to the overlay seen.
fn said_shown() -> Unit {
  let t = ps_now_ms()
  log(
    "capture \{mon.val.w}x\{mon.val.h}@\{num(mon_scale.untracked())}: taken \{num(took_ms.val)} ms (\{took_how.val}), handed over +\{num(taken_at.val - asked_at.val)}, seen +\{num(t - asked_at.val)} ms",
  )
}

///|
/// The mark picked, its handles (a line's ends, a box's corners) or, where it has none, a thin frame round it: in the
/// monitor's pixels, over the marks.
fn picked_picture() -> @pixels.Vector? {
  let m = match hand.get() {
    Dragging(_, _, _, _, _, _, _) => draft.get()
    _ =>
      match selected.get() {
        Some(id) => marks.get().iter().find_first(fn(m) { m.id == id })
        None => None
      }
  }
  guard m is Some(m) else { return None }
  let k = mon_scale.get()
  let layers : Array[@pixels.VectorPath] = []
  let handles = mark_handles(m)
  if handles.is_empty() {
    let (x0, y0, x1, y1) = mark_box(m, k)
    let pad = 4.0 * k
    layers.push(stroke_layer(rect_path(x0 - pad, y0 - pad, x1 - x0 + pad * 2.0, y1 - y0 + pad * 2.0), accent, k))
  }
  for h in handles {
    let (_, _, x, y) = h
    layers.push(fill_layer(circle_path(x, y, 5.0 * k), accent))
    layers.push(fill_layer(circle_path(x, y, 3.5 * k), 0xFFFFFFFFL))
  }
  Some({ w: mon.val.w.to_double(), h: mon.val.h.to_double(), layers })
}
