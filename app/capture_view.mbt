// Fullscreen frozen-screen selection & vector annotation overlay (@view.View tree).

///|
fn finish_capture(exit_if_oneshot : Bool) -> Unit {
  overlay_visible.set(false)
  ps_hide_window()
  if exit_if_oneshot {
    @ui.window_close_here(0)
  } else {
    let k = frozen_key.untracked()
    if k != "" {
      @ui.forget_image(k)
      frozen_key.set("")
    }
    frozen_bmp.val = b""
    ps_release_capture()
    ps_trim_memory()
  }
}

///|
fn do_copy_capture(oneshot : Bool) -> Unit {
  match export_selection_png() {
    Some(png) => {
      @ui.clipboard_set_png(png)
      if cfg_auto_save.untracked() {
        ps_auto_save_png(png, cstr(cfg_save_dir.untracked())) |> ignore
      }
      finish_capture(oneshot)
    }
    None => ()
  }
}

///|
fn do_save_capture(oneshot : Bool) -> Unit {
  match export_selection_png() {
    Some(png) =>
      if ps_save_png_dialog(png, cstr("PinShot.png")) == 1 {
        finish_capture(oneshot)
      }
    None => ()
  }
}

///|
fn do_pin_capture(oneshot : Bool) -> Unit {
  guard sel.untracked() is Some(r) else { return }
  match export_selection_png() {
    Some(png) => {
      let sc = mon_scale.val
      let px = mon_x.val + (r.x * sc).round().to_int()
      let py = mon_y.val + (r.y * sc).round().to_int()
      let pw = @cmp.maximum(16, (r.w * sc).round().to_int())
      let ph = @cmp.maximum(16, (r.h * sc).round().to_int())
      if ps_launch_pin(png, px, py, pw, ph) == 1 {
        finish_capture(oneshot)
      }
    }
    None => ()
  }
}

///|
fn hit_handle(x : Double, y : Double, r : BoxRect) -> Int {
  let pts : Array[(Int, Double, Double)] = [
    (3, r.x, r.y),
    (4, r.x + r.w / 2.0, r.y),
    (5, r.x + r.w, r.y),
    (6, r.x + r.w, r.y + r.h / 2.0),
    (7, r.x + r.w, r.y + r.h),
    (8, r.x + r.w / 2.0, r.y + r.h),
    (9, r.x, r.y + r.h),
    (10, r.x, r.y + r.h / 2.0),
  ]
  for p in pts {
    if (x - p.1).abs() <= 7.0 && (y - p.2).abs() <= 7.0 {
      return p.0
    }
  }
  0
}

///|
let is_selecting : @signals.Signal[Bool] = @signals.signal(false)

///|
fn on_canvas_drag(d : @view.Drag, oneshot : Bool) -> Unit {
  let ww = win_w.untracked()
  let wh = win_h.untracked()
  let x = clamp(d.x, 0.0, ww)
  let y = clamp(d.y, 0.0, wh)
  pointer_pos.set((x, y))
  match d.kind {
    Down => {
      drag_x0.val = x
      drag_y0.val = y
      match sel.untracked() {
        None => {
          drag_kind.val = 1
          is_selecting.set(true)
          hover_win.set(window_at(x, y))
        }
        Some(r) => {
          let h = hit_handle(x, y, r)
          if h != 0 {
            drag_kind.val = h
            drag_sel0.val = r
            return
          }
          let inside = x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h
          let tool = current_tool.untracked()
          if inside && tool != Select {
            drag_kind.val = 11
            if tool == Step {
              let n = step_counter.val
              step_counter.val += 1
              let list = annotations.untracked().copy()
              list.push({
                kind: Step,
                x0: x,
                y0: y,
                x1: x,
                y1: y,
                pts: [],
                color: current_color.untracked(),
                stroke: current_stroke.untracked(),
                step_num: n,
              })
              redo_stack.clear()
              annotations.set(list)
              drag_kind.val = 0
            } else {
              active_ann.set(Some({
                kind: tool,
                x0: x,
                y0: y,
                x1: x,
                y1: y,
                pts: if tool == Pen { [(x, y)] } else { [] },
                color: current_color.untracked(),
                stroke: current_stroke.untracked(),
                step_num: 0,
              }))
            }
          } else if inside {
            drag_kind.val = 2
            drag_sel0.val = r
          } else {
            drag_kind.val = 1
            is_selecting.set(true)
          }
        }
      }
    }
    Moved => {
      let k = drag_kind.val
      if k == 1 {
        let dx = (x - drag_x0.val).abs()
        let dy = (y - drag_y0.val).abs()
        if dx >= 3.0 || dy >= 3.0 {
          sel.set(Some({
            x: @cmp.minimum(drag_x0.val, x),
            y: @cmp.minimum(drag_y0.val, y),
            w: dx,
            h: dy,
          }))
          hover_win.set(None)
        }
      } else if k == 2 {
        let r0 = drag_sel0.val
        let nx = clamp(r0.x + (x - drag_x0.val), 0.0, @cmp.maximum(0.0, ww - r0.w))
        let ny = clamp(r0.y + (y - drag_y0.val), 0.0, @cmp.maximum(0.0, wh - r0.h))
        sel.set(Some({ ..r0, x: nx, y: ny }))
      } else if k >= 3 && k <= 10 {
        let r0 = drag_sel0.val
        let mut l = r0.x
        let mut t = r0.y
        let mut ri = r0.x + r0.w
        let mut b = r0.y + r0.h
        if k == 3 || k == 9 || k == 10 { l = clamp(x, 0.0, ri - 8.0) }
        if k == 5 || k == 6 || k == 7 { ri = clamp(x, l + 8.0, ww) }
        if k == 3 || k == 4 || k == 5 { t = clamp(y, 0.0, b - 8.0) }
        if k == 7 || k == 8 || k == 9 { b = clamp(y, t + 8.0, wh) }
        sel.set(Some({ x: l, y: t, w: ri - l, h: b - t }))
      } else if k == 11 {
        match active_ann.untracked() {
          Some(a) =>
            match sel.untracked() {
              Some(r) => {
                let cx = clamp(x, r.x, r.x + r.w)
                let cy = clamp(y, r.y, r.y + r.h)
                if a.kind == Pen {
                  let pts = a.pts.copy()
                  pts.push((cx, cy))
                  active_ann.set(Some({ ..a, x1: cx, y1: cy, pts }))
                } else {
                  active_ann.set(Some({ ..a, x1: cx, y1: cy }))
                }
              }
              None => ()
            }
          None => ()
        }
      }
    }
    Up | Off => {
      let k = drag_kind.val
      drag_kind.val = 0
      is_selecting.set(false)
      if k == 1 && (x - drag_x0.val).abs() < 3.0 && (y - drag_y0.val).abs() < 3.0 {
        // Click before selection -> snap to hovered window
        match window_at(x, y) {
          Some(wr) => {
            sel.set(Some(wr))
            hover_win.set(None)
          }
          None => ()
        }
      } else if k == 11 {
        match active_ann.untracked() {
          Some(a) => {
            active_ann.set(None)
            let valid = if a.kind == Pen {
              a.pts.length() >= 2
            } else {
              (a.x1 - a.x0).abs() >= 3.0 || (a.y1 - a.y0).abs() >= 3.0
            }
            if valid {
              let list = annotations.untracked().copy()
              list.push(a)
              redo_stack.clear()
              annotations.set(list)
            }
          }
          None => ()
        }
      }
      ignore(oneshot)
    }
  }
}

///|
fn tb_btn(
  parent : @view.View,
  label : String,
  active : () -> Bool,
  act : () -> Unit,
  primary? : Bool = false,
) -> Unit {
  parent.box(fn(b) {
    b
    .height(Is(Some(28.0)))
    .padding(Is((9.0, 0.0, 9.0, 0.0)))
    .radius(Is(6.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .cursor(Is(Some(Arrow)))
    .ground(By(fn() {
      if primary {
        if b.pointed() { 0x2563EBFFL } else { 0x3B82F6FFL }
      } else if active() {
        0x3B82F638L
      } else if b.pointed() {
        0xFFFFFF18L
      } else {
        0x00000000L
      }
    }))
    .edge(By(fn() {
      if active() && !primary {
        (1.0, 0x3B82F6FFL)
      } else {
        (0.0, 0L)
      }
    }))
    .on_press(fn() { act() })
    |> ignore
    b.box(fn(w) {
      w
      .words(Is(label), look={ ..@view.words_plain, size: 12.0, weight: if primary { 600 } else { 500 } })
      .ink(By(fn() {
        if primary || active() { 0xFFFFFFFFL } else { 0xE4E4E7FFL }
      }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn capture_overlay_view(root : @view.View, oneshot : Bool) -> Unit {
  let bindings = @view.Keymap::new([
    @view.Binding::{ keys: [@view.Stroke::{ code: 0x1B, mods: 0 }], action: "cancel", when: Always },
    @view.Binding::{ keys: [@view.Stroke::{ code: 0x0D, mods: 0 }], action: "copy", when: Always },
    @view.Binding::{ keys: [@view.Stroke::{ code: 'C'.to_int(), mods: 2 }], action: "copy", when: Always },
    @view.Binding::{ keys: [@view.Stroke::{ code: 'S'.to_int(), mods: 2 }], action: "save", when: Always },
    @view.Binding::{ keys: [@view.Stroke::{ code: 'Z'.to_int(), mods: 2 }], action: "undo", when: Always },
    @view.Binding::{ keys: [@view.Stroke::{ code: 'Y'.to_int(), mods: 2 }], action: "redo", when: Always },
  ])
  root.keymap(Is(bindings)) |> ignore
  root.on_action("cancel", fn(_) {
    finish_capture(oneshot)
    true
  }) |> ignore
  root.on_action("copy", fn(_) {
    do_copy_capture(oneshot)
    true
  }) |> ignore
  root.on_action("save", fn(_) {
    do_save_capture(oneshot)
    true
  }) |> ignore
  root.on_action("undo", fn(_) {
    undo_annotation()
    true
  }) |> ignore
  root.on_action("redo", fn(_) {
    redo_annotation()
    true
  }) |> ignore

  // Interactive frozen canvas
  root.box(fn(stage) {
    stage
    .width(By(fn() { Some(win_w.get()) }))
    .height(By(fn() { Some(win_h.get()) }))
    .presses(Is(true))
    .cursor(By(fn() {
      match sel.get() {
        None => Some(Crosshair)
        Some(r) => {
          let (px, py) = pointer_pos.get()
          let h = hit_handle(px, py, r)
          Some(if h != 0 { Arrow } else if current_tool.get() != Select { Crosshair } else { Arrow })
        }
      }
    }))
    .on_drag(fn(d) { on_canvas_drag(d, oneshot) })
    .on_double_press(fn() {
      if sel.untracked() is Some(_) && current_tool.untracked() == Select {
        do_copy_capture(oneshot)
      }
    })
    .on_menu(fn(_) {
      if sel.untracked() is Some(_) {
        reset_capture_state()
      } else {
        finish_capture(oneshot)
      }
    })
    |> ignore

    // 1. Frozen screenshot background
    stage.box(fn(bg) {
      bg
      .over(Is(true))
      .presses(Is(false))
      .width(By(fn() { Some(win_w.get()) }))
      .height(By(fn() { Some(win_h.get()) }))
      .image(By(fn() {
        let k = frozen_key.get()
        if k == "" { None } else { Some((k, "", mon_w.val)) }
      }))
      |> ignore
    }) |> ignore

    // 2. Dim scrim + selection / hovered window cutout
    stage.box(fn(scrim) {
      scrim
      .over(Is(true))
      .presses(Is(false))
      .width(By(fn() { Some(win_w.get()) }))
      .height(By(fn() { Some(win_h.get()) }))
      .picture(By(fn() {
        let ww = win_w.get()
        let wh = win_h.get()
        let active_box = match sel.get() {
          Some(r) => Some(r)
          None => hover_win.get()
        }
        let layers : Array[@pixels.VectorPath] = []
        match active_box {
          None =>
            layers.push(vec_layer(rect_svg(0.0, 0.0, ww, wh), 0x0000007AL))
          Some(r) => {
            if r.y > 0.0 {
              layers.push(vec_layer(rect_svg(0.0, 0.0, ww, r.y), 0x0000007AL))
            }
            if r.y + r.h < wh {
              layers.push(vec_layer(rect_svg(0.0, r.y + r.h, ww, wh - r.y - r.h), 0x0000007AL))
            }
            if r.x > 0.0 {
              layers.push(vec_layer(rect_svg(0.0, r.y, r.x, r.h), 0x0000007AL))
            }
            if r.x + r.w < ww {
              layers.push(vec_layer(rect_svg(r.x + r.w, r.y, ww - r.x - r.w, r.h), 0x0000007AL))
            }
            layers.push(vec_layer(rect_svg(r.x, r.y, r.w, r.h), 0L, stroke=0x3B82F6FFL, width=2.0))
          }
        }
        Some({ w: ww, h: wh, layers })
      }))
      |> ignore
    }) |> ignore

    // 3. Vector annotations inside selection
    stage.box(fn(ann_layer) {
      ann_layer
      .over(Is(true))
      .presses(Is(false))
      .clips(Is(true))
      .laid_nowhere(By(fn() { sel.get() is None }))
      .offset(By(fn() {
        match sel.get() {
          Some(r) => (r.x, r.y)
          None => (0.0, 0.0)
        }
      }))
      .width(By(fn() { sel.get().map(fn(r) { r.w }) }))
      .height(By(fn() { sel.get().map(fn(r) { r.h }) }))
      .picture(By(fn() {
        match sel.get() {
          Some(r) =>
            annotations_vector(
              annotations.get(),
              active_ann.get(),
              r.x,
              r.y,
              r.w,
              r.h,
              1.0,
              frozen_bmp.val,
              mon_w.val,
              mon_h.val,
              mon_scale.val,
            )
          None => None
        }
      }))
      |> ignore
    }) |> ignore

    // 4. 8 resize handles
    for idx in 0..<8 {
      stage.box(fn(h) {
        h
        .over(Is(true))
        .presses(Is(false))
        .width(Is(Some(8.0)))
        .height(Is(Some(8.0)))
        .radius(Is(4.0))
        .ground(Is(0xFFFFFFFFL))
        .edge(Is((1.5, 0x3B82F6FFL)))
        .laid_nowhere(By(fn() { sel.get() is None }))
        .offset(By(fn() {
          match sel.get() {
            None => (0.0, 0.0)
            Some(r) => {
              let (cx, cy) = match idx {
                0 => (r.x, r.y)
                1 => (r.x + r.w / 2.0, r.y)
                2 => (r.x + r.w, r.y)
                3 => (r.x + r.w, r.y + r.h / 2.0)
                4 => (r.x + r.w, r.y + r.h)
                5 => (r.x + r.w / 2.0, r.y + r.h)
                6 => (r.x, r.y + r.h)
                _ => (r.x, r.y + r.h / 2.0)
              }
              (cx - 4.0, cy - 4.0)
            }
          }
        }))
        |> ignore
      }) |> ignore
    }

    // 5. Dimension badge above selection
    stage.box(fn(badge) {
      badge
      .over(Is(true))
      .presses(Is(false))
      .width(Is(Some(92.0)))
      .height(Is(Some(22.0)))
      .padding(Is((7.0, 3.0, 7.0, 3.0)))
      .radius(Is(5.0))
      .ground(Is(0x18181BE6L))
      .edge(Is((1.0, 0xFFFFFF22L)))
      .laid_nowhere(By(fn() { sel.get() is None }))
      .offset(By(fn() {
        match sel.get() {
          None => (0.0, 0.0)
          Some(r) => {
            let y = if r.y >= 28.0 { r.y - 26.0 } else { r.y + 6.0 }
            (clamp(r.x, 6.0, @cmp.maximum(6.0, win_w.get() - 120.0)), y)
          }
        }
      }))
      |> ignore
      badge.box(fn(w) {
        w
        .words(By(fn() {
          match sel.get() {
            None => ""
            Some(r) => {
              let pw = (r.w * mon_scale.val).round().to_int()
              let ph = (r.h * mon_scale.val).round().to_int()
              "\{pw} × \{ph}"
            }
          }
        }), ink=0xF4F4F5FFL, look={ ..@view.words_plain, size: 11.0 })
        |> ignore
      }) |> ignore
    }) |> ignore

    // 6. Floating action & annotation toolbar
    stage.box(fn(bar) {
      bar
      .over(Is(true))
      .row(Is(true))
      .width(Is(Some(532.0)))
      .height(Is(Some(38.0)))
      .gap(Is(4.0))
      .padding(Is((8.0, 6.0, 8.0, 6.0)))
      .radius(Is(10.0))
      .ground(Is(0x18181BF2L))
      .edge(Is((1.0, 0xFFFFFF26L)))
      .shadow(Is((20.0, 6.0, 0x00000066L)))
      .lines_up(Is(Some(Middle)))
      .laid_nowhere(By(fn() { sel.get() is None || is_selecting.get() }))
      .offset(By(fn() {
        match sel.get() {
          None => (0.0, 0.0)
          Some(r) => {
            let ww = win_w.get()
            let wh = win_h.get()
            let bw = 532.0
            let tx = clamp(r.x + r.w - bw, 8.0, @cmp.maximum(8.0, ww - bw - 8.0))
            let ty = if r.y + r.h + 52.0 <= wh {
              r.y + r.h + 8.0
            } else if r.y >= 52.0 {
              r.y - 48.0
            } else {
              r.y + r.h - 48.0
            }
            (tx, ty)
          }
        }
      }))
      |> ignore

      let tools : Array[(Tool, String)] = [
        (Rect, "框"),
        (Ellipse, "圆"),
        (Arrow, "箭"),
        (Pen, "笔"),
        (Step, "序"),
        (Mosaic, "码"),
      ]
      for item in tools {
        let (tl, lbl) = item
        tb_btn(bar, lbl, fn() { current_tool.get() == tl }, fn() {
          current_tool.set(if current_tool.untracked() == tl { Select } else { tl })
        })
      }

      // Color dots
      bar.box(fn(sep) {
        sep.width(Is(Some(1.0))).height(Is(Some(18.0))).ground(Is(0xFFFFFF22L)).margin(Is((4.0, 0.0, 4.0, 0.0))) |> ignore
      }) |> ignore
      let colors : Array[Int64] = [0xEF4444FFL, 0xF59E0BFFL, 0x3B82F6FFL, 0x10B981FFL, 0xFFFFFFFFL]
      for col in colors {
        bar.box(fn(c) {
          c
          .width(Is(Some(16.0)))
          .height(Is(Some(16.0)))
          .radius(Is(8.0))
          .ground(Is(col))
          .edge(By(fn() {
            if current_color.get() == col { (2.0, 0xFFFFFFFFL) } else { (1.0, 0xFFFFFF44L) }
          }))
          .presses(Is(true))
          .cursor(Is(Some(Arrow)))
          .on_press(fn() { current_color.set(col) })
          |> ignore
        }) |> ignore
      }

      bar.box(fn(sep) {
        sep.width(Is(Some(1.0))).height(Is(Some(18.0))).ground(Is(0xFFFFFF22L)).margin(Is((4.0, 0.0, 4.0, 0.0))) |> ignore
      }) |> ignore

      tb_btn(bar, "撤", fn() { false }, undo_annotation)
      tb_btn(bar, "贴图", fn() { false }, fn() { do_pin_capture(oneshot) })
      tb_btn(bar, "保存", fn() { false }, fn() { do_save_capture(oneshot) })
      tb_btn(bar, "复制", fn() { false }, fn() { do_copy_capture(oneshot) }, primary=true)
      tb_btn(bar, "×", fn() { false }, fn() { finish_capture(oneshot) })
    }) |> ignore
  }) |> ignore
}
