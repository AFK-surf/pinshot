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
    (0, 0) => Arrow
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
    Drawing(_, _) | Marking | Erasing(_, _, _, _) => return Some(Crosshair)
    Moving(_, _, _) | Dragging(_, _, _, _, _, -1, _) => return Some(Arrow)
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
      let t = tool.get()
      match handle_at(r, x, y) {
        Some((0, 0)) =>
          if t == Pen || t == Eraser {
            Some(Crosshair)
          } else if t == Move || mark_at(x, y, false) is Some(_) {
            Some(Arrow)
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
  clear_part_now.get()
}

///|
/// What clear_part says, worked out once as the pointer or the part changes and kept: its readers (the veil, the
/// badge, the frame's motion, the magnifier's tag) read it, and are told only where it came to another rectangle; the
/// windows under the pointer, and the system asked whether a pane shows there, looked up once a move, not by each.
let clear_part_now : @signals.Computed[Rect?] = @signals.computed(fn(_) {
  match sel.get() {
    Some(r) => Some(r)
    None => window_under()
  }
})

///|
/// The veil, the frame of what is clear and, a part picked, its eight handles: one picture in the monitor's pixels.
fn chrome_picture(c : @view.View) -> @pixels.Vector? {
  if !capturing.get() {
    return None
  }
  let w = mon.val.w.to_double()
  let h = mon.val.h.to_double()
  let k = mon_scale.get()
  let picked = sel.get() is Some(_)
  let layers : Array[@pixels.VectorPath] = []
  // (where the part shows, on its way: shown.mbt)
  match shown_part(c) {
    Some(r) => {
      let (x, y, rw, rh) = (r.x.to_double(), r.y.to_double(), r.w.to_double(), r.h.to_double())
      // (the veil one path, the part a hole in it: no seam where two pieces would meet; laid on a background, the hole
      // is the whole picture as it will be copied)
      let hole = match shown_frame(c) {
        Some(f) => rect_path(f.x.to_double(), f.y.to_double(), f.w.to_double(), f.h.to_double())
        None => rect_path(x, y, rw, rh)
      }
      layers.push(fill_layer(rect_path(0.0, 0.0, w, h) + hole, 0x00000072L, even_odd=true))
      let line = dmax(1.5, (1.5 * k).round())
      let half = line / 2.0
      // Sit strictly outside the selection perimeter (0 px eaten inside content), clamped cleanly at monitor edges.
      let fx0 = dmax(half, x - half)
      let fy0 = dmax(half, y - half)
      let fx1 = dmin(w - half, x + rw + half)
      let fy1 = dmin(h - half, y + rh + half)
      let fw = dmax(1.0, fx1 - fx0)
      let fh = dmax(1.0, fy1 - fy0)
      let cr = if picked && beauty_on.get() { dmin(beauty_corner * k + half, dmin(fw, fh) / 2.0) } else { 0.0 }
      let frame_r = if cr > 0.5 { superellipse_rect_path(fx0, fy0, fw, fh, cr) } else { rect_path(fx0, fy0, fw, fh) }
      let casing_w = line + dmax(2.0, (2.0 * k).round())
      if !picked {
        // Hover auto-detect window: airy dual-contrast PinShot blue viewfinder outline + crisp corner accents
        layers.push(stroke_layer(frame_r, 0x00000066L, casing_w))
        layers.push(stroke_layer(frame_r, 0x3DA6FFFFL, line))
        let bl = clamp(dmin(fw, fh) * 0.14, 7.0 * k, 14.0 * k)
        let crn = "M\{num(fx0)} \{num(fy0 + bl)}L\{num(fx0)} \{num(fy0)}L\{num(fx0 + bl)} \{num(fy0)}" +
          "M\{num(fx1 - bl)} \{num(fy0)}L\{num(fx1)} \{num(fy0)}L\{num(fx1)} \{num(fy0 + bl)}" +
          "M\{num(fx0)} \{num(fy1 - bl)}L\{num(fx0)} \{num(fy1)}L\{num(fx0 + bl)} \{num(fy1)}" +
          "M\{num(fx1 - bl)} \{num(fy1)}L\{num(fx1)} \{num(fy1)}L\{num(fx1)} \{num(fy1 - bl)}"
        let bw = dmax(2.0, (2.4 * k).round())
        layers.push(stroke_layer(crn, 0x00000066L, bw + dmax(2.0, (2.0 * k).round())))
        layers.push(stroke_layer(crn, 0x9ED8FFFFL, bw))
      } else {
        // Confirmed selection (Proposal A): dual-contrast crisp white viewfinder line + L-brackets (rounded in
        // background mode to match the card's corners) + mid-edge pill grabbers
        layers.push(stroke_layer(frame_r, 0x00000078L, casing_w))
        layers.push(stroke_layer(frame_r, 0xFFFFFFF2L, line))
        if hand.get() != Marking {
          let bl = clamp(dmin(fw, fh) * 0.16, 8.0 * k, 15.0 * k)
          let bw = dmax(2.5, (3.2 * k).round())
          let b_case = bw + dmax(2.0, (2.4 * k).round())
          let (rr, cc) = if cr > 0.5 { superellipse_params(fw, fh, cr) } else { (0.0, 0.0) }
          let ext = if rr > 0.5 { clamp(dmax(bl, rr + 5.0 * k), rr, dmin(fw, fh) * 0.42) } else { bl }
          let crn = if rr > 0.5 {
            if ext > rr + 0.25 {
              "M\{num(fx0)} \{num(fy0 + ext)}V\{num(fy0 + rr)}C\{num(fx0)} \{num(fy0 + cc)} \{num(fx0 + cc)} \{num(fy0)} \{num(fx0 + rr)} \{num(fy0)}H\{num(fx0 + ext)}" +
              "M\{num(fx1 - ext)} \{num(fy0)}H\{num(fx1 - rr)}C\{num(fx1 - cc)} \{num(fy0)} \{num(fx1)} \{num(fy0 + cc)} \{num(fx1)} \{num(fy0 + rr)}V\{num(fy0 + ext)}" +
              "M\{num(fx1)} \{num(fy1 - ext)}V\{num(fy1 - rr)}C\{num(fx1)} \{num(fy1 - cc)} \{num(fx1 - cc)} \{num(fy1)} \{num(fx1 - rr)} \{num(fy1)}H\{num(fx1 - ext)}" +
              "M\{num(fx0 + ext)} \{num(fy1)}H\{num(fx0 + rr)}C\{num(fx0 + cc)} \{num(fy1)} \{num(fx0)} \{num(fy1 - cc)} \{num(fx0)} \{num(fy1 - rr)}V\{num(fy1 - ext)}"
            } else {
              "M\{num(fx0)} \{num(fy0 + rr)}C\{num(fx0)} \{num(fy0 + cc)} \{num(fx0 + cc)} \{num(fy0)} \{num(fx0 + rr)} \{num(fy0)}" +
              "M\{num(fx1 - rr)} \{num(fy0)}C\{num(fx1 - cc)} \{num(fy0)} \{num(fx1)} \{num(fy0 + cc)} \{num(fx1)} \{num(fy0 + rr)}" +
              "M\{num(fx1)} \{num(fy1 - rr)}C\{num(fx1)} \{num(fy1 - cc)} \{num(fx1 - cc)} \{num(fy1)} \{num(fx1 - rr)} \{num(fy1)}" +
              "M\{num(fx0 + rr)} \{num(fy1)}C\{num(fx0 + cc)} \{num(fy1)} \{num(fx0)} \{num(fy1 - cc)} \{num(fx0)} \{num(fy1 - rr)}"
            }
          } else {
            "M\{num(fx0)} \{num(fy0 + bl)}L\{num(fx0)} \{num(fy0)}L\{num(fx0 + bl)} \{num(fy0)}" +
            "M\{num(fx1 - bl)} \{num(fy0)}L\{num(fx1)} \{num(fy0)}L\{num(fx1)} \{num(fy0 + bl)}" +
            "M\{num(fx0)} \{num(fy1 - bl)}L\{num(fx0)} \{num(fy1)}L\{num(fx0 + bl)} \{num(fy1)}" +
            "M\{num(fx1 - bl)} \{num(fy1)}L\{num(fx1)} \{num(fy1)}L\{num(fx1)} \{num(fy1 - bl)}"
          }
          layers.push(stroke_layer(crn, 0x00000080L, b_case))
          layers.push(stroke_layer(crn, 0xFFFFFFFFL, bw))

          // Mid-edge directional pill grabbers (shown when side has comfortable breathing room)
          let plen = (14.0 * k).round()
          let pthk = dmax(3.0, (3.4 * k).round())
          let pcase = dmax(1.0, (1.2 * k).round())
          let min_side = dmax(54.0 * k, ext * 2.0 + plen + 12.0 * k)
          let mx = (fx0 + fx1) / 2.0
          let my = (fy0 + fy1) / 2.0
          let mut pills_case = ""
          let mut pills = ""
          if fw >= min_side {
            let px = mx - plen / 2.0
            let py_t = fy0 - pthk / 2.0
            let py_b = fy1 - pthk / 2.0
            pills_case = pills_case +
              round_rect_path(px - pcase, py_t - pcase, plen + pcase * 2.0, pthk + pcase * 2.0, (pthk + pcase * 2.0) / 2.0) +
              round_rect_path(px - pcase, py_b - pcase, plen + pcase * 2.0, pthk + pcase * 2.0, (pthk + pcase * 2.0) / 2.0)
            pills = pills +
              round_rect_path(px, py_t, plen, pthk, pthk / 2.0) +
              round_rect_path(px, py_b, plen, pthk, pthk / 2.0)
          }
          if fh >= min_side {
            let py = my - plen / 2.0
            let px_l = fx0 - pthk / 2.0
            let px_r = fx1 - pthk / 2.0
            pills_case = pills_case +
              round_rect_path(px_l - pcase, py - pcase, pthk + pcase * 2.0, plen + pcase * 2.0, (pthk + pcase * 2.0) / 2.0) +
              round_rect_path(px_r - pcase, py - pcase, pthk + pcase * 2.0, plen + pcase * 2.0, (pthk + pcase * 2.0) / 2.0)
            pills = pills +
              round_rect_path(px_l, py, pthk, plen, pthk / 2.0) +
              round_rect_path(px_r, py, pthk, plen, pthk / 2.0)
          }
          if pills != "" {
            layers.push(fill_layer(pills_case, 0x00000080L))
            layers.push(fill_layer(pills, 0xFFFFFFFFL))
          }
        }
      }
    }
    None => layers.push(fill_layer(rect_path(0.0, 0.0, w, h), 0x00000072L))
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
  } else if @hostapi.platform() != 0 && !capturing.untracked() && settings.untracked().capture_keep {
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
  root.ground(Is(0x000000FFL)).keymap(By(fn() { overlay_keys(settings.get().confirm_key) })) |> ignore
  overlay_actions(root)
  // (seen once its first frame with the picture is on the screen: on Windows ps_cloak(0, 0) uncloaks inside
  // held_shown_now() only after Present + GPU finish + DwmFlush so a cold first frame can never flash black)
  root.reacts(fn() {
    let key = frozen_key.get()
    key != "" && root.image_ready(key, dmax(mon.val.w.to_double(), mon.val.h.to_double()))
  }, fn(ready) {
    if ready && capturing.untracked() && !overlay_seen.untracked() {
      if @hostapi.platform() != 0 {
        if warming.val {
          overlay_seen.set(true)
          root.at_moment(root.cause_at() + 60.0, fn() { if warming.val { close_capture() } }, later=true) |> ignore
          return
        }
        if @ui.env("PINSHOT_TEST_CLOAKED") == "" {
          ps_cloak(0, 0)
        }
        overlay_seen.set(true)
        said_shown()
        return
      }
      root.at_moment(root.cause_at() + 1.0, fn() {
        if capturing.untracked() && warming.val {
          // (drawn whole once as if seen, its magnifier and its words too, still out of sight; then let go)
          overlay_seen.set(true)
          root.at_moment(root.cause_at() + 60.0, fn() { if warming.val { close_capture() } }, later=true) |> ignore
          return
        }
        if capturing.untracked() && !overlay_seen.untracked() {
          // (a test run told to keep it out of sight, PINSHOT_TEST_CLOAKED: driven and printed, never on the screen)
          if @ui.env("PINSHOT_TEST_CLOAKED") == "" {
            ps_cloak(0, 0)
          }
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
    // (where the part shows follows where it is, on its way: shown.mbt)
    shown_follow(stage)
    // (the background the part is laid on, while it is: beautify.mbt)
    beauty_layer(stage)
    marks_layer(stage, editing=true)
    // the veil, the frame, the handles
    stage.box(fn(c) { c.over(Is(true)).presses(Is(false)).picture(By(fn() { chrome_picture(c) })) |> ignore }) |> ignore
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
    // (the focus marks' dimming under the others: an arrow drawn over the dimmed part stays bright)
    layer.box(fn(f) { f.over(Is(true)).presses(Is(false)).picture(By(focus_picture)) |> ignore }) |> ignore
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
      let badge_in = @motion.NodeWay::new(if @signals.untracked(fn() { clear_part() is Some(_) }) { 1.0 } else { 0.0 })
      l.reacts(fn() { clear_part() is Some(_) }, at_start=false, fn(on) {
        if on {
          badge_in.go_from(l, 0.0, 1.0, @motion.tween(110.0, ease=Out))
        } else {
          badge_in.put(0.0)
        }
      })
      l
      .row(Is(true))
      .height(Is(Some(24.0)))
      .padding(Is((9.0, 0.0, 9.0, 0.0)))
      .radius(Is(7.5))
      .ground(Is(0x18191DF2L))
      .edge(Is((1.0, 0xFFFFFF2AL)))
      .shadow(Is((10.0, 3.0, 0x00000060L)))
      .alpha(By(fn() { badge_in.shown(l) }))
      .lines_up(Is(Some(Middle)))
      .laid_nowhere(By(fn() { clear_part() is None }))
      .offset(By(fn() {
        let k = mon_scale.get()
        match shown_whole(l) {
          Some(r) => {
            let (sw, sh) = mon_pt()
            let x = clamp(r.x.to_double() / k, 8.0, dmax(8.0, sw - 160.0))
            let ry = r.y.to_double() / k
            let y = if ry >= 34.0 { ry - 32.0 } else { clamp(ry + 8.0, 8.0, dmax(8.0, sh - 32.0)) }
            (x, y)
          }
          None => (0.0, 0.0)
        }
      }))
      |> ignore
      l.box(fn(t) {
        t
        .words(By(fn() {
          match (clear_part(), beauty_frame()) {
            (Some(r), Some(f)) => "\{r.w} × \{r.h} → \{f.w} × \{f.h}"
            (Some(r), None) => "\{r.w} × \{r.h}"
            _ => ""
          }
        }), look={ ..@view.words_plain, size: 12.0, weight: 500, line: 16.0, wrap: false })
        .ink(Is(0xF5F6F8FFL))
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
  match hand.untracked() {
    Dragging(_, _, _, before, _, _, _) | Erasing(before, _, _, _) => marks.set(before)
    _ => ()
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
        Some((0, 0)) => {
          let cur_tool = tool.untracked()
          if cur_tool == Eraser {
            selected.set(None)
            let before = marks.untracked()
            let hit = erase_pen_segment(x, y, x, y)
            erase_at.val = (x, y, hit)
            hand.set(Erasing(before, x, y, hit))
          } else if cur_tool == Pen {
            selected.set(None)
            hand.set(Marking)
            draft.set(Some(new_mark(Pen, [(x, y), (x, y)])))
          } else {
            match mark_at(x, y, cur_tool == Move) {
              // (on a mark: it is picked and dragged, whatever shape/line tool is held)
              Some(i) => take_up(i, x, y, -1, -1)
              None => {
                selected.set(None)
                match cur_tool {
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
          }
        }
        Some((hx, hy)) => {
          selected.set(None)
          hand.set(Sizing(hx, hy, r))
        }
        // (outside it: a part dragged out anew, where nothing is marked yet; but not on the background it is laid on,
        // which is the picture as it will be copied: a click there leaves the part as it is)
        None =>
          match beauty_frame() {
            Some(f) if f.contains(x, y) => ()
            _ => if marks.untracked().is_empty() { hand.set(Drawing(x, y)) }
          }
      }
  }
}

///|
/// The eraser's last point and whether it has erased anything yet, while it is dragged (Erasing).
let erase_at : Ref[(Double, Double, Bool)] = Ref((0.0, 0.0, false))

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
    Erasing(_, _, _, _) => {
      // (where it is and whether it erased kept apart, not in `hand`: set at each pixel it moved every binding that
      // reads `hand` again, comparing the marks as they were each time)
      let (lx, ly, hit) = erase_at.val
      let (cx, cy) = clamp_to_sel(x, y)
      let hit2 = erase_pen_segment(lx, ly, cx, cy)
      erase_at.val = (cx, cy, hit || hit2)
    }
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
          let pts = if m.tool == Pen || m.tool == MosaicBrush {
            let (lx, ly) = m.pts[m.pts.length() - 1]
            let dx = cx - lx
            let dy = cy - ly
            let min_step = if m.tool == MosaicBrush { 2.0 * mon_scale.untracked() } else { 0.5 }
            // (no point added: nothing copied, nothing set, nothing drawn again)
            if dx * dx + dy * dy < min_step * min_step {
              return
            }
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
/// Whether the first click of a potential double-click pushed an undoable mark/erase (undone if the second click lands).
let last_click_undo : Ref[Bool] = Ref(false)

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
  // (a double click inside the picked part finishes and copies immediately in ANY marking mode, discarding any stray
  // mark/erase/words box created by the double click itself)
  if moved {
    last_click.val = (0.0, 0.0, 0.0)
    last_click_undo.val = false
  } else if second_click(x, y) {
    match sel.untracked() {
      Some(r) if r.contains(x, y) => {
        drop_held()
        if words_open.untracked() is Some(_) {
          words_open.set(None)
        }
        if last_click_undo.val {
          undo() |> ignore
          last_click_undo.val = false
        }
        copy_out()
        return
      }
      _ => last_click_undo.val = false
    }
  } else {
    last_click_undo.val = false
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
    Erasing(before, _, _, _) => {
      let (_, _, hit) = erase_at.val
      if hit {
        done_before.val.push(before)
        undone.val = []
        if !moved {
          last_click_undo.val = true
        }
      }
      hand.set(Free)
      return
    }
    Marking =>
      match tool.untracked() {
        Number => {
          add_mark(new_mark(Number, [(x, y)]))
          if !moved {
            last_click_undo.val = true
          }
        }
        Words => if !words_put_down.val { open_words(x, y) }
        _ =>
          match draft.untracked() {
            Some(m) => {
              draft.set(None)
              if !too_small(m) {
                add_mark(m)
                if !moved {
                  last_click_undo.val = true
                }
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
/// Map a stored Win32-style Hotkey (Alt=1, Ctrl=2, Shift=4, Win=8) to mbui's (key_code, mods).
fn hotkey_to_mbui(h : Hotkey) -> (Int, Int)? {
  if h.vk == 0 {
    return None
  }
  let mut mods = 0
  if (h.mods & 4) != 0 {
    mods = mods | @ui.mod_shift_key
  }
  if (h.mods & 2) != 0 {
    mods = mods | @ui.mod_ctrl
  }
  if (h.mods & 1) != 0 {
    mods = mods | @ui.mod_alt
  }
  if (h.mods & 8) != 0 {
    mods = mods | @ui.mod_cmd
  }
  let code = match h.vk {
    0x0D => @ui.key_code_enter
    0x20 => @ui.key_space
    0x09 => @ui.key_tab
    0x24 => @ui.key_code_home
    0x23 => @ui.key_code_end
    0x21 => @ui.key_code_page_up
    0x22 => @ui.key_code_page_down
    v if v >= 0x41 && v <= 0x5A => 1000 + (v - 0x41 + 97)
    v if v >= 0x30 && v <= 0x39 => 1000 + v
    v if v >= 0x70 && v <= 0x7B => 100 + (v - 0x70)
    _ => return None
  }
  Some((code, mods))
}

///|
fn overlay_keys(confirm : Hotkey) -> @view.Keymap {
  let k = fn(code : Int, action : String, mods : Int) -> @view.Binding {
    { keys: [{ code, mods }], action, when: Always }
  }
  let ch = fn(c : Char, action : String, mods : Int) { k(@ui.key_of_char(c), action, mods) }
  let ctrl = shortcut_mod()
  let shift = @ui.mod_shift_key
  let list : Array[@view.Binding] = []
  match hotkey_to_mbui(confirm) {
    Some((code, mods)) => list.push(k(code, "copy", mods))
    None => ()
  }
  let rest : Array[@view.Binding] = [
    k(@ui.key_escape, "close", 0),
    k(@ui.key_code_delete, "delete", 0),
    ch('v', "select", 0),
    k(@ui.key_code_backspace, "delete", 0),
    k(@ui.key_code_enter, "copy", 0),
    ch('c', "copy", ctrl),
    k(@ui.key_code_copy, "copy", ctrl),
    ch('s', "save", ctrl),
    ch('t', "pin", ctrl),
    ch('o', "ocr", ctrl),
    ch('l', "long", ctrl),
    ch('r', "record", ctrl),
    ch('z', "undo", ctrl),
    ch('y', "redo", ctrl),
    ch('z', "redo", ctrl | shift),
    ch('c', "copy-color", 0),
    ch('b', "beautify", 0),
    // (the whole monitor at once: as PixPin's Ctrl+A)
    ch('a', "whole", ctrl),
    k(@ui.key_code_select_all, "whole", ctrl),
    k(@ui.key_code_left, "left", 0),
    k(@ui.key_code_right, "right", 0),
    k(@ui.key_code_up, "up", 0),
    k(@ui.key_code_down, "down", 0),
    k(@ui.key_code_left, "left10", shift),
    k(@ui.key_code_right, "right10", shift),
    k(@ui.key_code_up, "up10", shift),
    k(@ui.key_code_down, "down10", shift),
  ]
  for b in rest {
    list.push(b)
  }
  @view.Keymap::new(list)
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
    } else if tool.untracked() != Move {
      tool.set(Move)
    } else {
      close_capture()
    }
  })
  on("delete", fn() { delete_selected() |> ignore })
  on("select", fn() { tool.set(Move) })
  on("copy", copy_out)
  on("save", save_out)
  on("pin", pin_out)
  on("ocr", ocr_out)
  on("long", long_out)
  on("record", rec_out)
  on("undo", fn() { undo() |> ignore })
  on("redo", fn() { redo() |> ignore })
  on("copy-color", copy_color)
  on("beautify", beauty_toggle)
  // (the whole monitor picked: a window covering all of it but the taskbar is what a click picks, so the screen whole is
  // hard to get to by the pointer: the user, 2026-11-20 「现在似乎挺难直接截全屏」)
  on("whole", fn() {
    if marks.untracked().is_empty() {
      selected.set(None)
      sel.set(Some({ x: 0, y: 0, w: mon.val.w, h: mon.val.h }))
    }
  })
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
  // Eraser brush preview circle when hovering/erasing inside the selection
  if tool.get() == Eraser {
    match sel.get() {
      Some(r) => {
        let (px, py) = pointer_px.get()
        if r.contains(px, py) {
          let k = mon_scale.get()
          let rad = eraser_pt(size_now.get()) * k
          return Some({
            w: mon.val.w.to_double(),
            h: mon.val.h.to_double(),
            layers: [
              fill_layer(circle_path(px, py, rad), 0xFFFFFF26L),
              stroke_layer(circle_path(px, py, rad), 0x00000088L, dmax(1.0, k * 2.0)),
              stroke_layer(circle_path(px, py, rad), 0xFFFFFFFFL, dmax(1.0, k)),
            ],
          })
        }
      }
      None => ()
    }
  }
  // (a mosaic being dragged out: where it reaches, a thin frame of the accent round a faint tint of it, its squares
  // alone showing nothing over an even ground)
  if hand.get() is Marking && draft.get() is Some(d) && (d.tool == Mosaic || d.tool == Blur) {
    let k = mon_scale.get()
    let (x0, y0) = d.pts[0]
    let (x1, y1) = d.pts[d.pts.length() - 1]
    let (x, y, w, h) = (dmin(x0, x1), dmin(y0, y1), (x1 - x0).abs(), (y1 - y0).abs())
    if w < 1.0 || h < 1.0 {
      return None
    }
    let t = dmax(1.0, k.round())
    return Some({
      w: mon.val.w.to_double(),
      h: mon.val.h.to_double(),
      layers: [
        fill_layer(rect_path(x, y, w, h), 0x2F9BFF14L),
        fill_layer(rect_path(x, y, w, h) + rect_path(x + t, y + t, w - t * 2.0, h - t * 2.0), accent, even_odd=true),
      ],
    })
  }
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
  if handles.is_empty() || m.tool == Mosaic || m.tool == Blur {
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
