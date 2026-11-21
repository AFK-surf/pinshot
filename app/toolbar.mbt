// The tool bar of a part picked: under it at its right edge (over it where the screen has no room under it, inside it
// where it has none over it either), dark whatever the theme, as it lies on a picture of anything. Concentric mbui
// superellipse corners (main bar 40pt high, corner 15pt, 4pt padding, 32pt buttons corner 11pt; style row 36pt high,
// corner 13pt, 28pt buttons corner 9pt, every corner at smoothness 1.0) with 13 buttons on the main row: select,
// shapes (box / oval / focus), lines (arrow / line), pen, mosaic, number, words | undo | extract text (OCR), pin,
// save, close, copy. Choosing shapes or lines shows their variants on the left of the second row beside thickness and colour.

///|
let bar_button : Double = 32.0

///|
let bar_pad : Double = 4.0

///|
let bar_corner : Double = 15.0

///|
let bar_btn_corner : Double = 11.0

///|
let style_corner : Double = 13.0

///|
let style_btn_corner : Double = 9.0

///|
let bar_rule : Double = 7.0

///|
/// Between the bar's buttons (their grounds as they are pointed at or lit apart, the user, 2026-11-17).
let bar_gap : Double = 3.0

///|
/// The current variant remembered for the folded shape button (Box, Oval, Focus), line button (Arrow, Line) and
/// mosaic button (Mosaic, MosaicBrush, Blur).
let shape_tool : @signals.Signal[Tool] = @signals.signal(Box)

///|
let line_tool : @signals.Signal[Tool] = @signals.signal(Arrow)

///|
let mosaic_tool : @signals.Signal[Tool] = @signals.signal(Mosaic)

///|
fn is_shape_tool(t : Tool) -> Bool {
  match t {
    Box | Oval | Focus => true
    _ => false
  }
}

///|
fn is_line_tool(t : Tool) -> Bool {
  match t {
    Arrow | Line => true
    _ => false
  }
}

///|
fn is_pen_tool(t : Tool) -> Bool {
  match t {
    Pen | Eraser => true
    _ => false
  }
}

///|
fn is_mosaic_tool(t : Tool) -> Bool {
  match t {
    Mosaic | MosaicBrush | Blur => true
    _ => false
  }
}

///|
fn tool_glyph(t : Tool) -> String {
  match t {
    Move => "select"
    Box => "box"
    Oval => "oval"
    Focus => "focus"
    Arrow => "arrow"
    Line => "line"
    Pen => "pen"
    Eraser => "eraser"
    Mosaic => "mosaic"
    MosaicBrush => "mosaic-brush"
    Blur => "blur"
    Number => "number"
    Words => "words"
  }
}

///|
fn tool_label(t : Tool) -> String {
  match t {
    Move => "选择（V）"
    Box => "矩形"
    Oval => "椭圆"
    Focus => "聚焦（框出重点，其余变暗）"
    Arrow => "箭头（按住 Shift 水平、垂直或 45°）"
    Line => "直线（按住 Shift 水平、垂直或 45°）"
    Pen => "画笔"
    Eraser => "橡皮擦（涂抹擦除画笔）"
    Mosaic => "像素马赛克（框选打码）"
    MosaicBrush => "涂抹马赛克（按住涂抹打码）"
    Blur => "模糊遮罩（平滑柔化打码）"
    Number => "序号"
    Words => "文字"
  }
}

///|
/// The standalone drawing tools after the folded shape, line and mosaic buttons.
let bar_rest_tools : Array[Tool] = [Number, Words]

///|
let shape_variants : Array[Tool] = [Box, Oval, Focus]

///|
let line_variants : Array[Tool] = [Arrow, Line]

///|
let pen_variants : Array[Tool] = [Pen, Eraser]

///|
let mosaic_variants : Array[Tool] = [Mosaic, MosaicBrush, Blur]

///|
/// 14 buttons on the main bar (+1 scrolling screenshot, +1 screen record on Windows).
fn bar_width() -> Double {
  let n = 14.0 + (if long_shot_here() { 1.0 } else { 0.0 }) + (if rec_here() { 1.0 } else { 0.0 })
  bar_pad * 2.0 + bar_button * n + bar_rule * 2.0 + bar_gap * (n + 1.0)
}

///|
let bar_height : Double = 40.0

///|
let style_height : Double = 36.0

///|
/// Where the bar stands (points): under the part at its right edge, kept on the screen.
fn bar_place(n : @view.View) -> (Double, Double) {
  let k = mon_scale.get()
  let (sw, sh) = mon_pt()
  // (under the picture as it will be copied, where it shows on its way: the part, or the background it is laid on)
  guard sel.get() is Some(_) else { return (0.0, 0.0) }
  match shown_whole(n) {
    Some(r) => {
      let rx1 = r.right().to_double() / k
      let ry0 = r.y.to_double() / k
      let ry1 = r.bottom().to_double() / k
      let w = bar_width()
      let h = bar_height +
        (if styling() { style_height + 4.0 } else { 0.0 }) +
        (if beauty_on.get() { style_height + 4.0 } else { 0.0 })
      let x = clamp(rx1 - w, 4.0, sw - w - 4.0)
      let y = if ry1 + 8.0 + h <= sh - 4.0 {
        ry1 + 8.0
      } else if ry0 - 8.0 - h >= 4.0 {
        ry0 - 8.0 - h
      } else {
        ry1 - h - 8.0
      }
      (x, y)
    }
    None => (0.0, 0.0)
  }
}

///|
fn pick_tool(which : Tool) -> Unit {
  if words_open.untracked() is Some(_) {
    commit_words()
  }
  tool.set(if tool.untracked() == which { Move } else { which })
}

///|
///|
/// Active tool slot index on the main bar's left tool strip (0..6).
fn main_tool_slot() -> Int {
  let t = tool.get()
  if t == Move {
    0
  } else if is_shape_tool(t) {
    1
  } else if is_line_tool(t) {
    2
  } else if is_pen_tool(t) {
    3
  } else if is_mosaic_tool(t) {
    4
  } else if t == Number {
    5
  } else if t == Words {
    6
  } else {
    -1
  }
}

///|
/// The main screenshot toolbar row view, used to hand its exact screen rect to the recording bar on transition.
let toolbar_main_view : Ref[@view.View?] = Ref(None)

///|
/// Exact screen rect (x, y, w, h in monitor-local points) of the main screenshot toolbar row, if mounted and laid out.
fn toolbar_main_rect() -> (Double, Double, Double, Double)? {
  match toolbar_main_view.val {
    Some(v) if v.alive() => {
      let (x, y, w, h) = v.laid_window_now()
      if w > 20.0 && h > 10.0 {
        Some((x, y, w, h))
      } else {
        None
      }
    }
    _ => None
  }
}

///|
fn toolbar(stage : @view.View) -> Unit {
  stage.box(fn(o) {
    o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
    o.box(fn(col) {
      let bar_shown = fn() {
        sel.get() is Some(_) &&
        (match hand.get() {
          Drawing(_, _) | Moving(_, _, _) | Sizing(_, _, _) => false
          _ => true
        })
      }
      let bar_in = @motion.NodeWay::new(if @signals.untracked(bar_shown) { 1.0 } else { 0.0 })
      col.reacts(bar_shown, at_start=false, fn(on) {
        if on {
          bar_in.go_from(col, 0.0, 1.0, @motion.tween(130.0, ease=Out))
        } else {
          bar_in.put(0.0)
        }
      })
      col
      .gap(Is(4.0))
      // (each row as wide as what it holds, from the bar's left: the style row is not stretched to the bar's width)
      .lines_up(Is(Some(Start)))
      .offset(By(fn() { bar_place(col) }))
      .alpha(By(fn() { bar_in.shown(col) }))
      .drawn_off(By(fn() { (0.0, 4.0 * (1.0 - bar_in.shown(col))) }))
      // (out of the way while the part is dragged or resized)
      .laid_nowhere(By(fn() { !bar_shown() }))
      |> ignore
      col.box(fn(bar) {
        toolbar_main_view.val = Some(bar)
        bar.owns(fn() { toolbar_main_view.val = None }) |> ignore
        bar_panel(bar, bar_corner)
        bar.row(Is(true)).gap(Is(bar_gap)).width(Is(Some(bar_width()))) |> ignore
        // Left tool group (0..6) with a gliding active-tool pill underneath the icons
        bar.box(fn(tg) {
          tg.row(Is(true)).gap(Is(bar_gap)).lines_up(Is(Some(Middle))) |> ignore
          let tool_views : Map[Int, @view.View] = Map([])
          sliding_thumb(tg, main_tool_slot, tool_views, bar_btn_corner, fn() { 0xFFFFFF2EL })
          // 1. Select (Move)
          tool_button(
            tg,
            "select",
            "选择",
            fn() { tool.get() == Move },
            fn() { pick_tool(Move) },
            keys=fn() { "V" },
            slot_views=Some((0, tool_views)),
          )
          // 2. Folded Shape group (Box / Oval / Focus)
          tool_group_button(
            tg,
            fn() {
              let t = tool.get()
              tool_glyph(if is_shape_tool(t) { t } else { shape_tool.get() })
            },
            fn() {
              let t = tool.get()
              tool_label(if is_shape_tool(t) { t } else { shape_tool.get() })
            },
            fn() { is_shape_tool(tool.get()) },
            fn() {
              if words_open.untracked() is Some(_) {
                commit_words()
              }
              if is_shape_tool(tool.untracked()) {
                tool.set(Move)
              } else {
                tool.set(shape_tool.untracked())
              }
            },
            slot_views=Some((1, tool_views)),
          )
          // 3. Folded Line/Arrow group (Arrow / Line)
          tool_group_button(
            tg,
            fn() {
              let t = tool.get()
              tool_glyph(if is_line_tool(t) { t } else { line_tool.get() })
            },
            fn() {
              let t = tool.get()
              tool_label(if is_line_tool(t) { t } else { line_tool.get() })
            },
            fn() { is_line_tool(tool.get()) },
            fn() {
              if words_open.untracked() is Some(_) {
                commit_words()
              }
              if is_line_tool(tool.untracked()) {
                tool.set(Move)
              } else {
                tool.set(line_tool.untracked())
              }
            },
            slot_views=Some((2, tool_views)),
          )
          // 4. Pen / Eraser group (always opens as Pen; second row offers Pen & Eraser)
          tool_button(
            tg,
            "pen",
            "画笔",
            fn() { is_pen_tool(tool.get()) },
            fn() {
              if words_open.untracked() is Some(_) {
                commit_words()
              }
              if is_pen_tool(tool.untracked()) {
                tool.set(Move)
              } else {
                selected.set(None)
                tool.set(Pen)
              }
            },
            slot_views=Some((3, tool_views)),
          )
          // 5. Folded Mosaic group (Mosaic / MosaicBrush / Blur)
          tool_group_button(
            tg,
            fn() {
              let t = tool.get()
              tool_glyph(if is_mosaic_tool(t) { t } else { mosaic_tool.get() })
            },
            fn() {
              let t = tool.get()
              tool_label(if is_mosaic_tool(t) { t } else { mosaic_tool.get() })
            },
            fn() { is_mosaic_tool(tool.get()) },
            fn() {
              if words_open.untracked() is Some(_) {
                commit_words()
              }
              if is_mosaic_tool(tool.untracked()) {
                tool.set(Move)
              } else {
                tool.set(mosaic_tool.untracked())
              }
            },
            slot_views=Some((4, tool_views)),
          )
          // 6..7. Number, Words
          for idx, which in bar_rest_tools {
            tool_button(
              tg,
              tool_glyph(which),
              tool_label(which),
              fn() { tool.get() == which },
              fn() { pick_tool(which) },
              slot_views=Some((5 + idx, tool_views)),
            )
          }
        })
        |> ignore
        // 8. The background the part is laid on (beautify.mbt)
        tool_button(bar, "beautify", "美化背景", fn() { beauty_on.get() }, beauty_toggle, keys=fn() { "B" })
        bar_rule_node(bar)
        // 9. Undo (Redo stays on Ctrl+Y / Ctrl+Shift+Z)
        tool_button(bar, "undo", "撤销", fn() { false }, fn() { undo() |> ignore }, dim=fn() {
          marks.get() |> ignore
          done_before.val.is_empty()
        }, keys=fn() { "Ctrl+Z" })
        bar_rule_node(bar)
        // 9..15. OCR, scrolling screenshot & screen record (Windows'), Pin, Save, Close, Copy
        tool_button(bar, "ocr", "提取文字", fn() { false }, ocr_out, keys=fn() { "Ctrl+O" })
        if long_shot_here() {
          tool_button(bar, "long", "长截图", fn() { false }, long_out, keys=fn() { "Ctrl+L" })
        }
        if rec_here() {
          tool_button(bar, "record", "录屏", fn() { false }, rec_out, keys=fn() { "Ctrl+R" })
        }
        tool_button(bar, "pin", "贴到屏幕", fn() { false }, pin_out, keys=fn() { "Ctrl+T" })
        tool_button(bar, "save", "保存截图", fn() { false }, save_out, keys=fn() { "Ctrl+S" })
        tool_button(bar, "close", "关闭", fn() { false }, close_capture, keys=fn() { "Esc" })
        tool_button(bar, "check", "复制", fn() { false }, copy_out, strong=true, keys=confirm_key_label)
      })
      |> ignore
      col.show(fn() { styling() }, leave=115.0, fn(slot) {
        dropdown_unfold(slot, style_height, style_row)
      })
      col.show(fn() { beauty_on.get() }, leave=115.0, fn(slot) {
        dropdown_unfold(slot, style_height, beauty_row)
      })
    })
    |> ignore
    bar_tip_node(o)
  })
  |> ignore
}

///|
fn bar_panel(b : @view.View, rad : Double) -> Unit {
  b
  .pad(Is(bar_pad))
  .radius(Is(rad))
  .ground(Is(0x1E1F23F7L))
  .edge(Is((1.0, 0xFFFFFF1FL)))
  .shadow(Is((18.0, 4.0, 0x00000073L)))
  .lines_up(Is(Some(Middle)))
  .presses(Is(true))
  .cursor(Is(Some(Arrow)))
  |> ignore
}

///|
fn bar_rule_node(bar : @view.View, shown? : () -> Bool = fn() { true }) -> Unit {
  bar.box(fn(r) {
    r
    .laid_nowhere(By(fn() { !shown() }))
    .width(Is(Some(bar_rule)))
    .height(Is(Some(20.0)))
    .lies_along(Is(Middle))
    .lines_up(Is(Some(Middle)))
    |> ignore
    r.box(fn(l) { l.width(Is(Some(1.0))).height(Is(Some(16.0))).ground(Is(0xFFFFFF24L)) |> ignore }) |> ignore
  })
  |> ignore
}

///|
/// A button of the bar: its glyph, lit while `on`; faint where `dim` (nothing to undo).
fn tool_button(
  bar : @view.View,
  glyph_name : String,
  label : String,
  on : () -> Bool,
  press : () -> Unit,
  dim? : () -> Bool = fn() { false },
  strong? : Bool = false,
  tip? : Bool = true,
  keys? : () -> String = fn() { "" },
  slot_views? : (Int, Map[Int, @view.View])? = None,
) -> Unit {
  tool_group_button(bar, fn() { glyph_name }, fn() { label }, on, press, dim~, strong~, tip~, keys~, slot_views~)
}

///|
/// A button of the bar whose glyph and label may follow the active sub-tool in a folded group.
fn tool_group_button(
  bar : @view.View,
  glyph_fn : () -> String,
  label_fn : () -> String,
  on : () -> Bool,
  press : () -> Unit,
  dim? : () -> Bool = fn() { false },
  strong? : Bool = false,
  tip? : Bool = true,
  keys? : () -> String = fn() { "" },
  slot_views? : (Int, Map[Int, @view.View])? = None,
) -> Unit {
  // (`tip`: told by the overlay's tip; a button of another window, the long screenshot's panel, is not: the tip is the
  // overlay's, its node ids of no other window)
  bar.box(fn(b) {
    let has_slider = match slot_views {
      Some((idx, views)) => {
        views[idx] = b
        true
      }
      None => false
    }
    let live = fn() { !dim() }
    let hov = smooth_hover(b, live~, ms=100.0)
    let act = @motion.eased_on(b, on, @motion.tween(120.0, ease=Out))
    tactile_press(b, live~, sink_px=1.0)
    b
    .width(Is(Some(bar_button)))
    .height(Is(Some(bar_button)))
    .radius(Is(bar_btn_corner))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .says(By(fn() { Some(@view.said(Button, label=tr(label_fn()))) }))
    .on_press(fn() {
      if tip {
        tip_off()
      }
      if !dim() {
        press()
      }
    })
    .ground(By(fn() {
      if b.pressed() && !dim() {
        0xFFFFFF24L
      } else if has_slider && on() {
        0L
      } else {
        let rest = mix_rgba(0L, 0xFFFFFF17L, hov())
        if has_slider { rest } else { mix_rgba(rest, 0xFFFFFF2EL, act.shown(b)) }
      }
    }))
    |> ignore
    if tip {
      tip_follows(b, label_fn, @view.Top, keys~)
    }
    b.box(fn(g) {
      g
      .width(Is(Some(18.0)))
      .height(Is(Some(18.0)))
      .picture(By(fn() { Some(glyph(glyph_fn())) }))
      .tint(By(fn() {
        if dim() {
          0xFFFFFF4DL
        } else if strong {
          0x4CC38AFFL
        } else {
          mix_rgba(0xD9DBE0FFL, 0xFFFFFFFFL, dmax(act.shown(g), hov() * 0.6))
        }
      }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Whether the second row is shown: a tool held, or a mark picked (its colour and thickness then).
fn styling() -> Bool {
  tool.get() != Move || selected.get() is Some(_)
}

///|
/// Variant tool at slot `idx` (0..2) for sub-tool group `grp` (1=shape, 2=line, 3=pen, 4=mosaic).
fn sub_tool_of(grp : Int, idx : Int) -> Tool? {
  let arr = match grp {
    1 => shape_variants
    2 => line_variants
    3 => pen_variants
    4 => mosaic_variants
    _ => []
  }
  if idx >= 0 && idx < arr.length() {
    Some(arr[idx])
  } else {
    None
  }
}

///|
fn pick_sub_tool(grp : Int, which : Tool) -> Unit {
  if grp == 1 {
    shape_tool.set(which)
    tool.set(which)
  } else if grp == 2 {
    line_tool.set(which)
    tool.set(which)
  } else if grp == 3 {
    selected.set(None)
    tool.set(which)
  } else if grp == 4 {
    mosaic_tool.set(which)
    tool.set(which)
  }
}

///|
/// Single persistent 3-slot sub-tool strip: switching tool groups only swaps icons (no fade/scale transition on the
/// active/hover shade); clicking within the same group still glides the active highlight smoothly.
fn sub_tool_strip(left_slot : @view.View, shown_grp : @signals.Signal[Int]) -> Unit {
  left_slot.box(fn(btns) {
    btns.row(Is(true)).gap(Is(bar_gap)).height(Is(Some(28.0))).lines_up(Is(Some(Middle))) |> ignore
    let views : Map[Int, @view.View] = Map([])
    let active_idx = fn() {
      let g = shown_grp.get()
      let cur = tool.get()
      for i in 0..<3 {
        if sub_tool_of(g, i) == Some(cur) {
          return i
        }
      }
      -1
    }
    sliding_thumb(
      btns,
      active_idx,
      views,
      style_btn_corner,
      fn() { 0xFFFFFF2EL },
      snap_watch=fn() { shown_grp.get() },
    )
    for i in 0..<3 {
      btns.box(fn(b) {
        views[i] = b
        let has = fn() { sub_tool_of(shown_grp.get(), i) is Some(_) }
        let is_on = fn() {
          match sub_tool_of(shown_grp.get(), i) {
            Some(w) => tool.get() == w
            None => false
          }
        }
        let hov = smooth_hover(b, live=has, ms=100.0)
        tactile_press(b, live=has, sink_px=1.0)
        b
        .laid_nowhere(By(fn() { !has() }))
        .width(Is(Some(28.0)))
        .height(Is(Some(28.0)))
        .radius(Is(style_btn_corner))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .presses(By(has))
        .points(By(has))
        .says(By(fn() {
          match sub_tool_of(shown_grp.get(), i) {
            Some(w) => Some(@view.said(Button, label=tr(tool_label(w))))
            None => None
          }
        }))
        .on_press(fn() {
          let g = shown_grp.untracked()
          match sub_tool_of(g, i) {
            Some(w) => {
              tip_off()
              pick_sub_tool(g, w)
            }
            None => ()
          }
        })
        .ground(By(fn() {
          if b.pressed() && has() {
            0xFFFFFF24L
          } else if is_on() {
            0L
          } else {
            mix_rgba(0L, 0xFFFFFF17L, hov())
          }
        }))
        |> ignore
        tip_follows(b, fn() {
          match sub_tool_of(shown_grp.get(), i) {
            Some(w) => tool_label(w)
            None => ""
          }
        }, @view.Bottom)
        b.box(fn(g) {
          g
          .width(Is(Some(17.0)))
          .height(Is(Some(17.0)))
          .picture(By(fn() {
            match sub_tool_of(shown_grp.get(), i) {
              Some(w) => Some(glyph(tool_glyph(w)))
              None => None
            }
          }))
          .tint(By(fn() {
            if is_on() {
              0xFFFFFFFFL
            } else {
              mix_rgba(0xD9DBE0FFL, 0xFFFFFFFFL, hov() * 0.6)
            }
          }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    }
  })
  |> ignore
  // Persistent divider tucked cleanly against the right edge of `left_slot` so it rides lockstep with `left_w`.
  left_slot.box(fn(d) {
    d
    .over_at(Is((None, Some(4.0), Some(bar_gap), None)))
    .width(Is(Some(bar_rule)))
    .height(Is(Some(20.0)))
    .lies_along(Is(Middle))
    .lines_up(Is(Some(Middle)))
    .laid_nowhere(By(fn() { shown_grp.get() == 0 }))
    |> ignore
    d.box(fn(l) { l.width(Is(Some(1.0))).height(Is(Some(16.0))).ground(Is(0xFFFFFF24L)) |> ignore }) |> ignore
  })
  |> ignore
}

///|
fn style_left_width(grp : Int) -> Double {
  match grp {
    1 | 4 => 3.0 * 28.0 + 2.0 * bar_gap + bar_gap + bar_rule + bar_gap
    2 | 3 => 2.0 * 28.0 + bar_gap + bar_gap + bar_rule + bar_gap
    _ => 0.0
  }
}

///|
fn style_pill_width(grp : Int, has_col : Bool) -> Double {
  let sz_w = 3.0 * 28.0 + 2.0 * bar_gap
  let col_w = if has_col {
    bar_gap + bar_rule + bar_gap + colors.length().to_double() * 28.0 + (colors.length() - 1).to_double() * bar_gap
  } else {
    0.0
  }
  bar_pad * 2.0 + style_left_width(grp) + sz_w + col_w
}

///|
/// The second row: smoothly animates its superellipse capsule length, clips unveiled/collapsing controls cleanly,
/// crossfades sub-tool groups, and glides thickness & color controls in lockstep across every tool switch.
fn style_row(row : @view.View) -> Unit {
  let active_grp = fn() -> Int {
    let t = tool.get()
    if is_shape_tool(t) {
      1
    } else if is_line_tool(t) {
      2
    } else if is_pen_tool(t) {
      3
    } else if is_mosaic_tool(t) {
      4
    } else {
      0
    }
  }
  let has_color = fn() -> Bool {
    let t = tool.get()
    if t != Move {
      !is_mosaic_tool(t) && t != Focus && t != Eraser
    } else {
      match selected.get() {
        Some(id) =>
          match mark_index(id) {
            Some(i) => {
              let mt = marks.get()[i].tool
              !is_mosaic_tool(mt) && mt != Focus
            }
            None => true
          }
        None => true
      }
    }
  }
  let init_grp = @signals.untracked(active_grp)
  let init_col = @signals.untracked(has_color)
  let shown_grp : @signals.Signal[Int] = @signals.signal(init_grp)
  let shown_col : @signals.Signal[Bool] = @signals.signal(init_col)

  let pill_w = @motion.NodeWay::new(style_pill_width(init_grp, init_col))
  let left_w = @motion.NodeWay::new(style_left_width(init_grp))
  let color_a = @motion.NodeWay::new(if init_col { 1.0 } else { 0.0 })

  let shell_ref : Ref[@view.View?] = Ref(None)
  let left_ref : Ref[@view.View?] = Ref(None)
  let csec_ref : Ref[@view.View?] = Ref(None)

  row.box(fn(shell) {
    shell_ref.val = Some(shell)
    shell
    .width(By(fn() { Some(pill_w.shown(shell)) }))
    .height(Is(Some(style_height)))
    .radius(Is(style_corner))
    .ground(Is(0x1E1F23F7L))
    .edge(Is((1.0, 0xFFFFFF1FL)))
    .shadow(Is((18.0, 4.0, 0x00000073L)))
    .presses(Is(true))
    .cursor(Is(Some(Arrow)))
    |> ignore

    // Clipped inner viewport filling the exact animated superellipse shell so unveiling/collapsing sections never spill
    shell.box(fn(clip) {
      clip
      .width(By(fn() { Some(pill_w.shown(clip)) }))
      .height(Is(Some(style_height)))
      .radius(Is(style_corner))
      .clips(Is(true))
      .pad(Is(bar_pad))
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      |> ignore

      // 1. Left sub-tool variant slot (smoothly expands/shrinks 0 ↔ 72 ↔ 103pt; persistent buttons swap icons cleanly without fading the highlight box)
      clip.box(fn(left_slot) {
        left_ref.val = Some(left_slot)
        left_slot
        .width(By(fn() { Some(left_w.shown(left_slot)) }))
        .height(Is(Some(28.0)))
        .shrink(Is(0.0))
        .clips(Is(true))
        |> ignore
        sub_tool_strip(left_slot, shown_grp)
      })
      |> ignore

      // 2. Thickness group (fixed 90pt; glides smoothly in lockstep with left_slot width)
      let sz_w = 3.0 * 28.0 + 2.0 * bar_gap
      clip.box(fn(sz_grp) {
        sz_grp
        .width(Is(Some(sz_w)))
        .height(Is(Some(28.0)))
        .shrink(Is(0.0))
        .row(Is(true))
        .gap(Is(bar_gap))
        .lines_up(Is(Some(Middle)))
        |> ignore
        let sz_views : Map[Int, @view.View] = Map([])
        sliding_thumb(sz_grp, fn() { size_now.get() }, sz_views, style_btn_corner, fn() { 0xFFFFFF2EL })
        for s in 0..<3 {
          sz_grp.box(fn(b) {
            sz_views[s] = b
            let hov = smooth_hover(b, ms=100.0)
            tactile_press(b, sink_px=0.9)
            b
            .width(Is(Some(28.0)))
            .height(Is(Some(28.0)))
            .radius(Is(style_btn_corner))
            .lines_up(Is(Some(Middle)))
            .lies_along(Is(Middle))
            .presses(Is(true))
            .says(By(fn() { Some(@view.said(Button, label=tr(["细", "中", "粗"][s]))) }))
            .on_press(fn() {
              tip_off()
              size_now.set(s)
              restyle_selected(s~)
            })
            .ground(By(fn() { if size_now.get() == s { 0L } else { mix_rgba(0L, 0xFFFFFF17L, hov()) } }))
            |> ignore
            tip_follows(b, fn() { ["细", "中", "粗"][s] }, @view.Bottom)
            let d = [4.0, 7.0, 11.0][s]
            b.box(fn(dot) {
              dot.width(Is(Some(d))).height(Is(Some(d))).radius(Is(d / 2.0)).ground(Is(0xE6E8ECFFL)) |> ignore
            })
            |> ignore
          })
          |> ignore
        }
      })
      |> ignore

      // 3. Color swatches section (kept mounted inside clipped viewport so right edge smoothly unveils/sweeps over swatches)
      let col_w = bar_gap + bar_rule + bar_gap + colors.length().to_double() * 28.0 + (colors.length() - 1).to_double() * bar_gap
      clip.box(fn(csec) {
        csec_ref.val = Some(csec)
        csec
        .width(Is(Some(col_w)))
        .height(Is(Some(28.0)))
        .shrink(Is(0.0))
        .padding(Is((bar_gap, 0.0, 0.0, 0.0)))
        .row(Is(true))
        .gap(Is(bar_gap))
        .lines_up(Is(Some(Middle)))
        .alpha(By(fn() { color_a.shown(csec) }))
        .points(By(fn() { shown_col.get() }))
        .presses(By(fn() { shown_col.get() }))
        |> ignore
        bar_rule_node(csec)
        for c in colors {
          csec.box(fn(b) {
            let live = fn() { shown_col.get() }
            let hov = smooth_hover(b, live~, ms=100.0)
            tactile_press(b, live~, sink_px=0.9)
            b
            .width(Is(Some(28.0)))
            .height(Is(Some(28.0)))
            .radius(Is(style_btn_corner))
            .lines_up(Is(Some(Middle)))
            .lies_along(Is(Middle))
            .presses(By(live))
            .points(By(live))
            .says(Is(Some(@view.said(Button, label=hex6((c >> 8).to_int())))))
            .on_press(fn() {
              if !shown_col.untracked() {
                return
              }
              color_now.set(c)
              restyle_selected(c~)
            })
            .ground(By(fn() { mix_rgba(0L, 0xFFFFFF17L, hov()) }))
            |> ignore
            b.box(fn(sw) {
              let on_c = @motion.eased_on(sw, fn() { color_now.get() == c }, @motion.tween(120.0, ease=Out))
              sw
              .width(Is(Some(16.0)))
              .height(Is(Some(16.0)))
              .radius(Is(5.0))
              .ground(Is(c))
              .scale(By(fn() { 1.0 + 0.08 * on_c.shown(sw) }))
              .edge(By(fn() {
                let p = on_c.shown(sw)
                (1.0 + p, mix_rgba(0xFFFFFF33L, 0xFFFFFFFFL, p))
              }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore

  // Drive synchronized width & crossfade transitions on tool / selection changes (frozen while closing so fade-out stays clean)
  row.reacts(fn() { (styling(), active_grp(), has_color()) }, at_start=false, fn(st) {
    let (is_on, grp, col_on) = st
    if !is_on {
      return
    }
    shown_grp.set(grp)
    shown_col.set(col_on)
    let morph_spec = @motion.tween(185.0, ease=Out)
    match shell_ref.val {
      Some(sh) if sh.alive() => pill_w.go(sh, style_pill_width(grp, col_on), morph_spec)
      _ => ()
    }
    match left_ref.val {
      Some(ls) if ls.alive() => left_w.go(ls, style_left_width(grp), morph_spec)
      _ => ()
    }
    match csec_ref.val {
      Some(cs) if cs.alive() =>
        color_a.go(cs, if col_on { 1.0 } else { 0.0 }, @motion.tween(if col_on { 155.0 } else { 115.0 }, ease=Out))
      _ => ()
    }
  })
}

///|
/// The bar's glyphs, on an 18 grid, 1.6 wide lines (drawn in their node's tint).
fn glyph(name : String) -> @pixels.Vector {
  let lines = fn(paths : Array[String]) -> @pixels.Vector {
    { w: 18.0, h: 18.0, layers: paths.map(fn(d) { stroke_layer(d, 0x000000FFL, 1.6) }) }
  }
  match name {
    "select" =>
      {
        w: 18.0,
        h: 18.0,
        layers: [stroke_layer("M5 2.8v11.4l2.9-2.8 2.1 4.6 2-.9-2.1-4.5h4z", 0x000000FFL, 1.4)],
      }
    "focus" =>
      {
        w: 18.0,
        h: 18.0,
        layers: [
          fill_layer("M2 3h14v12h-14zM6 6.5v5h6v-5z", 0x00000073L),
          stroke_layer("M6 6.5h6v5h-6z", 0x000000FFL, 1.6),
        ],
      }
    "box" => lines(["M3.5 4.5h11v9h-11z"])
    "oval" => lines([oval_path(2.5, 4.0, 13.0, 10.0)])
    "arrow" => lines(["M4 14 14 4", "M7.5 4H14v6.5"])
    "line" => lines(["M3.5 14.5 14.5 3.5"])
    "pen" => lines(["M3.5 14.5l1-3.5 8-8 2.5 2.5-8 8z", "M11 4.5l2.5 2.5"])
    "mosaic" =>
      {
        w: 18.0,
        h: 18.0,
        layers: [
          stroke_layer("M3.5 3.5h11v11h-11z", 0x000000FFL, 1.6),
          fill_layer("M3.5 3.5h3.7v3.7h-3.7zM10.8 3.5h3.7v3.7h-3.7zM7.2 7.2h3.6v3.6h-3.6zM3.5 10.8h3.7v3.7h-3.7zM10.8 10.8h3.7v3.7h-3.7z", 0x000000FFL),
        ],
      }
    "mosaic-brush" =>
      {
        w: 18.0,
        h: 18.0,
        layers: [
          fill_layer("M2.5 12.8h2.6v2.6H2.5zM5.6 12.8h2.6v2.6H5.6zM2.5 9.7h2.6v2.6H2.5z", 0x000000FFL),
          stroke_layer("M7.5 11.8l.9-3.1 5.6-5.6 2.2 2.2-5.6 5.6z", 0x000000FFL, 1.5),
        ],
      }
    "blur" =>
      {
        w: 18.0,
        h: 18.0,
        layers: [
          fill_layer(circle_path(9.0, 9.0, 6.2), 0x00000040L),
          stroke_layer(circle_path(9.0, 9.0, 6.2), 0x000000FFL, 1.5),
          fill_layer(circle_path(9.0, 9.0, 3.0), 0x0000008CL),
        ],
      }
    "number" =>
      {
        w: 18.0,
        h: 18.0,
        layers: [
          stroke_layer(circle_path(9.0, 9.0, 6.5), 0x000000FFL, 1.6),
          fill_layer("M8.3 6.4l1.6-1v7.4h-1.6z", 0x000000FFL),
        ],
      }
    "words" => lines(["M4 5V3.8h10V5", "M9 3.8v10.7", "M7 14.5h4"])
    "beautify" =>
      {
        w: 18.0,
        h: 18.0,
        layers: [
          stroke_layer(
            "M5.6 2.8h6.8c1.8 0 2.8 1 2.8 2.8v6.8c0 1.8-1 2.8-2.8 2.8H5.6c-1.8 0-2.8-1-2.8-2.8V5.6c0-1.8 1-2.8 2.8-2.8z",
            0x000000FFL,
            1.6,
          ),
          fill_layer("M7 6h4c.6 0 1 .4 1 1v4c0 .6-.4 1-1 1H7c-.6 0-1-.4-1-1V7c0-.6.4-1 1-1z", 0x000000FFL),
        ],
      }
    "ocr" => lines(["M2.8 6V2.8H6", "M12 2.8h3.2V6", "M15.2 12v3.2H12", "M6 15.2H2.8V12", "M6 6.5h6", "M9 6.5v5.5"])
    "undo" => lines(["M6.5 4 3 7.5 6.5 11", "M3.5 7.5h7a4 4 0 0 1 0 8H8"])
    "redo" => lines(["M11.5 4 15 7.5 11.5 11", "M14.5 7.5h-7a4 4 0 0 0 0 8H10"])
    "pin" => lines(["M7 2.8h4l-.6 4.6 2.6 2.4v1.4H5v-1.4l2.6-2.4z", "M9 11.2v4.3"])
    "save" => lines(["M9 3v8.5", "M5.5 8 9 11.5 12.5 8", "M3.5 13v1.7h11V13"])
    "close" => lines(["M4.5 4.5l9 9", "M13.5 4.5l-9 9"])
    "check" => { w: 18.0, h: 18.0, layers: [stroke_layer("M3.5 9.5 7.3 13.2 14.5 5", 0x000000FFL, 2.0)] }
    "copy" => lines(["M6.5 6.5h8v8h-8z", "M11.5 6.5V3.5h-8v8h3"])
    // (a page taller than its frame, an arrow down it: a long screenshot)
    "long" => lines(["M4 2.5h10v13h-10z", "M9 5.5v7", "M6.5 10 9 12.5 11.5 10"])
    "top" => lines(["M9 15V5", "M5 9l4-4 4 4", "M4 2.8h10"])
    "pause" => lines(["M6.5 4.2v9.6", "M11.5 4.2v9.6"])
    "play" => { w: 18.0, h: 18.0, layers: [fill_layer("M6 4.2 14 9 6 13.8z", 0x000000FFL)] }
    "record" =>
      {
        w: 18.0,
        h: 18.0,
        layers: [
          stroke_layer(circle_path(9.0, 9.0, 6.2), 0x000000FFL, 1.5),
          fill_layer(circle_path(9.0, 9.0, 3.2), 0x000000FFL),
        ],
      }
    "stop" =>
      {
        w: 18.0,
        h: 18.0,
        layers: [fill_layer("M5.5 4.5h7c.6 0 1 .4 1 1v7c0 .6-.4 1-1 1h-7c-.6 0-1-.4-1-1v-7c0-.6.4-1 1-1z", 0x000000FFL)],
      }
    "speaker" => lines(["M3 7.2h2.8l3.7-3.2v10l-3.7-3.2H3z", "M12.2 6.8a3.2 3.2 0 0 1 0 4.4", "M14.3 4.8a6 6 0 0 1 0 8.4"])
    "speaker-off" => lines(["M3 7.2h2.8l3.7-3.2v10l-3.7-3.2H3z", "M12.2 7l3.3 4", "M15.5 7l-3.3 4"])
    "keycap" =>
      lines(["M2.5 4.5h13c.7 0 1.2.5 1.2 1.2v6.6c0 .7-.5 1.2-1.2 1.2h-13c-.7 0-1.2-.5-1.2-1.2V5.7c0-.7.5-1.2 1.2-1.2z", "M5.2 8h1.5", "M8.3 8h1.5", "M11.4 8h1.5", "M6 10.8h6"])
    "eraser" => lines(["M4.2 11.2 9.8 5.6a1.5 1.5 0 0 1 2.1 0l2.5 2.5a1.5 1.5 0 0 1 0 2.1l-3.6 3.6H6.8z", "M7.5 8l4 4", "M3.5 13.8h11"])
    "reset" => lines(["M4.2 7.5a5 5 0 1 1 1.2 4.9", "M4.2 3.8v3.7h3.7"])
    _ => lines([])
  }
}

// Monoid-style fluid tooltips (aligned with still.fail libs/sf-ui/src/tip_node.mbt + motion/handoff.mbt):
// - 10pt superellipse, lifted charcoal ground, 9% hairline, soft small shadow, concentric 6pt shortcut keycap badges.
// - Ground-first 120ms fade-in (Ease::Out) and words-first 120ms fade-out with 0.97 scale toward anchor (FromBeside).
// - Critically-damped spring handoff (0.09s) gliding position, width, height & carried content smoothly across buttons
//   on the same side when sweeping along the toolbar.

///|
let tip_wait : Double = 400.0

///|
let tip_linger : Double = 300.0

///|
let tip_in_ms : Double = 120.0

///|
let tip_out_ms : Double = 120.0

///|
let tip_out_scale : Double = 0.97

///|
/// Overlay layer node that hosts all toolbar tooltips (painted on top of the bar and sub-rows).
let tip_layer : Ref[@view.View?] = Ref(None)

///|
/// Active tooltip owner id (only one tooltip owns the window slot at any instant; 0 = none).
let tip_owner : @signals.Signal[Int] = @signals.signal(0)

///|
let tip_next_id : Ref[Int] = Ref(0)

///|
/// Shared upstream mbui handoff coordinator for toolbar tooltips (glides ground & carried text across buttons).
let tip_hands : @motion.Handoff = @motion.Handoff::new(within=tip_linger)

///|
let tip_went_at : Ref[Double] = Ref(-1.0e18)

///|
let tip_shut_now : Ref[() -> Unit] = Ref(fn() {  })

///|
/// Monoid TipFade: smooth continuous progress (0..1) with mid-flight reversal.
priv struct TipFade {
  mut from : Double
  mut to : Double
  mut start : Double
  mut ms : Double
  mut ease : @ui.Ease
  moving : @signals.Signal[Bool]
  mut due : (() -> Unit)?
}

///|
fn TipFade::new() -> TipFade {
  { from: 0.0, to: 0.0, start: 0.0, ms: 0.0, ease: Out, moving: @signals.signal(false, same=fn(a, b) { a == b }), due: None }
}

///|
fn TipFade::at(self : TipFade, t : Double) -> Double {
  if self.ms <= 0.0 || t >= self.start + self.ms {
    return self.to
  }
  let p = (t - self.start) / self.ms
  self.from + (self.to - self.from) * self.ease.at(if p < 0.0 { 0.0 } else { p })
}

///|
fn TipFade::stop(self : TipFade) -> Unit {
  match self.due {
    Some(s) => s()
    None => ()
  }
  self.due = None
}

///|
fn TipFade::go(self : TipFade, node : @view.View, to : Double, at : Double, ms : Double, ease : @ui.Ease) -> Unit {
  self.from = self.at(at)
  self.to = to
  self.start = at
  self.ms = ms
  self.ease = ease
  self.stop()
  self.moving.set(true)
  self.due = Some(node.at_moment(at + ms, fn() { self.moving.set(false) }))
}

///|
fn TipFade::put(self : TipFade, to : Double) -> Unit {
  self.from = to
  self.to = to
  self.start = 0.0
  self.ms = 0.0
  self.stop()
  self.moving.set(false)
}

///|
fn TipFade::shown(self : TipFade, v : @view.View) -> Double {
  if self.moving.get() {
    self.at(v.drawn_at())
  } else {
    self.to
  }
}

///|
fn tip_side_tag(side : @view.Side) -> Int {
  match side {
    Top => 0
    Right => 1
    Bottom => 2
    Left => 3
  }
}

///|
fn tip_off() -> Unit {
  tip_owner.set(0)
  (tip_shut_now.val)()
  tip_shut_now.val = fn() {  }
  tip_went_at.val = -1.0e18
}

///|
/// Split a shortcut string ("Ctrl+R", "⌘⇧Z", "Enter") into individual Monoid-style keycap labels.
fn tip_key_caps(keys : String) -> Array[String] {
  let caps : Array[String] = []
  let trimmed = keys.trim(chars=" ").to_owned()
  if trimmed == "" {
    return caps
  }
  let on_mac = @hostapi.platform() == 0
  let chars = trimmed.to_array()
  let is_mark = fn(c : Char) { c == '⌃' || c == '⌥' || c == '⇧' || c == '⌘' }
  if is_mark(chars[0]) {
    let mut at = 0
    while at < chars.length() && is_mark(chars[at]) {
      caps.push(chars[at].to_string())
      at += 1
    }
    let rest = String::from_array(chars[at:]).trim(chars=" ").to_owned()
    if rest != "" {
      caps.push(rest)
    }
    return caps
  }
  let mut part : Array[Char] = []
  for c in chars {
    if c == '+' && !part.is_empty() {
      let s = String::from_array(part).trim(chars=" ").to_owned()
      caps.push(if on_mac && s == "Ctrl" { "⌘" } else if on_mac && s == "Alt" { "⌥" } else if on_mac && s == "Shift" { "⇧" } else { s })
      part = []
    } else {
      part.push(c)
    }
  }
  if !part.is_empty() {
    let s = String::from_array(part).trim(chars=" ").to_owned()
    caps.push(if on_mac && s == "Enter" { "Return" } else { s })
  }
  caps
}

///|
/// Button `b` tells what it does (`label`, said through `tr`) and optional shortcut (`keys`) via a Monoid-style
/// fluid-transition tooltip on `side` (ground-first fade-in, 0.97 scale-out, critically-damped spring glide between
/// buttons on the same side).
fn tip_follows(b : @view.View, label : () -> String, side : @view.Side, keys? : () -> String = fn() { "" }) -> Unit {
  let anchor_id = b.id()
  tip_next_id.val = tip_next_id.val + 1
  let id = tip_next_id.val
  let fade = TipFade::new()
  let open : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })
  let glide = tip_hands.part(
    fn(t) {
      if @signals.untracked(fn() { tip_owner.get() == id }) {
        fade.at(t)
      } else {
        0.0
      }
    },
    tag=tip_side_tag(side),
    gave=fn() {
      fade.put(0.0)
      open.set(false)
    },
  )
  let made = Ref(false)
  let holder_v : Ref[@view.View?] = Ref(None)
  let shut = Ref(false)
  let rest : Ref[(() -> Unit)?] = Ref(None)
  let stop_rest = fn() {
    match rest.val {
      Some(cancel) => cancel()
      None => ()
    }
    rest.val = None
  }
  let make = fn() -> Bool {
    guard tip_layer.val is Some(l) else { return false }
    let holder = l.box(fn(h) { h.transitions_only().over(Is(true)) |> ignore }).lives_with(b)
    holder_v.val = Some(holder)
    holder.show(fn() { open.get() }, leave=tip_out_ms, fn(t) {
      let caps = tip_key_caps(@signals.untracked(keys))
      let has_keys = !caps.is_empty()
      t
      .beside(anchor_id, side~, along=Middle, offset=6.0, padding=4.0)
      .presses(Is(false))
      .points(Is(false))
      .padding(Is(if has_keys { (10.0, 4.0, 4.0, 4.0) } else { (10.0, 5.0, 10.0, 5.0) }))
      .radius(Is(10.0))
      .ground(Is(0x26282FF7L))
      .edge(Is((1.0, 0xFFFFFF18L)))
      .shadow(Is((8.0, 2.0, 0x00000048L)))
      // Ground fades in first half (0..60ms), words in second half (60..120ms); reversed on exit
      .alpha(By(fn() {
        let a = if tip_owner.get() == id { fade.shown(t) } else { 0.0 }
        if a * 2.0 < 1.0 {
          a * 2.0
        } else {
          1.0
        }
      }))
      // Gentle 0.97 shrink toward the button while exiting
      .scale(
        By(fn() {
          let a = fade.shown(t)
          if fade.to > 0.5 {
            1.0
          } else {
            tip_out_scale + (1.0 - tip_out_scale) * a
          }
        }),
        about=@view.FromBeside,
      )
      .hides(By(fn() { tip_owner.get() != id }))
      |> ignore
      let content = t.box(fn(content) {
        content
        .row(Is(true))
        .gap(Is(7.0))
        .lines_up(Is(Some(Middle)))
        .alpha(By(fn() {
          let a = fade.shown(t)
          let g = if a * 2.0 < 1.0 { a * 2.0 } else { 1.0 }
          let w = if a * 2.0 - 1.0 > 0.0 { a * 2.0 - 1.0 } else { 0.0 }
          if g > 0.0 {
            w / g
          } else {
            0.0
          }
        }))
        |> ignore
        content.box(fn(w) {
          w
          .padding(Is((0.0, 1.0, 0.0, 1.0)))
          .words(By(fn() { tr(label()) }), look={ ..@view.words_plain, size: 12.0, weight: 500, line: 16.0, wrap: false })
          .ink(Is(0xECEEF2FFL))
          |> ignore
        })
        |> ignore
        if has_keys {
          content.box(fn(q) {
            q.row(Is(true)).gap(Is(2.0)).lines_up(Is(Some(Middle))) |> ignore
            for cap in caps {
              q.box(fn(k) {
                k
                .height(Is(Some(19.0)))
                .min_width(Is(Some(19.0)))
                .padding(Is((5.0, 0.0, 5.0, 0.0)))
                .radius(Is(6.0))
                .ground(Is(0xFFFFFF1FL))
                .lines_up(Is(Some(Middle)))
                .lies_along(Is(Middle))
                |> ignore
                k.box(fn(kw) {
                  kw
                  .words(Is(cap), look={ ..@view.words_plain, size: 11.0, weight: 500, line: 14.0, wrap: false })
                  .ink(Is(0xE6E8EDFFL))
                  |> ignore
                })
                |> ignore
              })
              |> ignore
            }
          })
          |> ignore
        }
      })
      glide.draws(t, carries=content)
    })
    true
  }
  let set_open = fn(on : Bool) {
    if on == open.untracked() {
      return
    }
    let at = b.cause_at()
    if on {
      // Take over from the previous tooltip BEFORE claiming tip_owner, so prev's seen(at) still sees it as active.
      let taken = glide.came(at, @motion.hand_spring)
      if !made.val {
        made.val = make()
      }
      if made.val {
        tip_owner.set(id)
        tip_shut_now.val = fn() {
          fade.put(0.0)
          glide.still()
          open.set(false)
        }
      }
      match taken {
        Some(_) => fade.put(1.0)
        None => fade.go(b, 1.0, at, tip_in_ms, Out)
      }
    } else {
      fade.go(b, 0.0, at, tip_out_ms, Leave)
      tip_went_at.val = at
      glide.left(at)
    }
    match holder_v.val {
      Some(h) if h.alive() => @view.transition(within=h, fn() { open.set(on) })
      _ => open.set(on)
    }
  }
  b.reacts(fn() { (b.pointed(), b.pressed()) }, fn(st) {
    let (pointed, pressed) = st
    let at = b.cause_at()
    stop_rest()
    if pressed {
      shut.val = true
    } else if !pointed {
      shut.val = false
    }
    if shut.val || !pointed {
      set_open(false)
    } else if open.untracked() {
      tip_owner.set(id)
    } else if at < tip_went_at.val + tip_linger || glide.other_near(at) {
      set_open(true)
    } else {
      rest.val = Some(
        b.at_moment(at + tip_wait, fn() {
          if b.pointed() && !b.pressed() && !shut.val {
            set_open(true)
          }
        }),
      )
    }
  })
  b.owns(fn() {
    stop_rest()
    fade.stop()
    glide.gone()
  })
  |> ignore
}

///|
/// Mount the overlay layer that hosts all fluid Monoid-style tooltips above the toolbar.
fn bar_tip_node(o : @view.View) -> Unit {
  o.box(fn(l) {
    l.over(Is(true)).presses(Is(false)).points(Is(false)) |> ignore
    tip_layer.val = Some(l)
  })
  |> ignore
}
