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
let mosaic_variants : Array[Tool] = [Mosaic, MosaicBrush, Blur]

///|
/// 14 buttons on the main bar (15 where a scrolling screenshot can be taken): 7 tools + the background + rule + 1 undo
/// + rule + 5 actions (6) = 16 items (17), 15 gaps (16).
fn bar_width() -> Double {
  let n = if long_shot_here() { 15.0 } else { 14.0 }
  bar_pad * 2.0 + bar_button * n + bar_rule * 2.0 + bar_gap * (n + 1.0)
}

///|
let bar_height : Double = 40.0

///|
let style_height : Double = 36.0

///|
/// Where the bar stands (points): under the part at its right edge, kept on the screen.
fn bar_place() -> (Double, Double) {
  let k = mon_scale.get()
  let (sw, sh) = mon_pt()
  // (under the picture as it will be copied: the part, or the background it is laid on)
  match beauty_or(sel.get()) {
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
fn toolbar(stage : @view.View) -> Unit {
  stage.box(fn(o) {
    o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
    bar_tip_node(o)
    o.box(fn(col) {
      col
      .gap(Is(4.0))
      // (each row as wide as what it holds, from the bar's left: the style row is not stretched to the bar's width)
      .lines_up(Is(Some(Start)))
      .offset(By(bar_place))
      // (out of the way while the part is dragged or resized)
      .laid_nowhere(By(fn() {
        sel.get() is None ||
        (match hand.get() {
          Drawing(_, _) | Moving(_, _, _) | Sizing(_, _, _) => true
          _ => false
        })
      }))
      |> ignore
      col.box(fn(bar) {
        bar_panel(bar, bar_corner)
        bar.row(Is(true)).gap(Is(bar_gap)).width(Is(Some(bar_width()))) |> ignore
        // 1. Select (Move)
        tool_button(bar, "select", "选择（V）", fn() { tool.get() == Move }, fn() { pick_tool(Move) })
        // 2. Folded Shape group (Box / Oval / Focus)
        tool_group_button(
          bar,
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
        )
        // 3. Folded Line/Arrow group (Arrow / Line)
        tool_group_button(
          bar,
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
        )
        // 4. Pen
        tool_button(bar, "pen", "画笔", fn() { tool.get() == Pen }, fn() { pick_tool(Pen) })
        // 5. Folded Mosaic group (Mosaic / MosaicBrush / Blur)
        tool_group_button(
          bar,
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
        )
        // 6..7. Number, Words
        for which in bar_rest_tools {
          tool_button(bar, tool_glyph(which), tool_label(which), fn() { tool.get() == which }, fn() {
            pick_tool(which)
          })
        }
        // 8. The background the part is laid on (beautify.mbt)
        tool_button(bar, "beautify", "美化背景 B", fn() { beauty_on.get() }, beauty_toggle)
        bar_rule_node(bar)
        // 9. Undo (Redo stays on Ctrl+Y / Ctrl+Shift+Z)
        tool_button(bar, "undo", "撤销 Ctrl+Z", fn() { false }, fn() { undo() |> ignore }, dim=fn() {
          marks.get() |> ignore
          done_before.val.is_empty()
        })
        bar_rule_node(bar)
        // 9..14. OCR, a scrolling screenshot (Windows'), Pin, Save, Close, Copy
        tool_button(bar, "ocr", "提取文字 Ctrl+O", fn() { false }, ocr_out)
        if long_shot_here() {
          tool_button(bar, "long", "长截图 Ctrl+L", fn() { false }, long_out)
        }
        tool_button(bar, "pin", "贴到屏幕 Ctrl+T", fn() { false }, pin_out)
        tool_button(bar, "save", "保存 Ctrl+S", fn() { false }, save_out)
        tool_button(bar, "close", "关闭 Esc", fn() { false }, close_capture)
        tool_button(bar, "check", "复制 Enter", fn() { false }, copy_out, strong=true)
      })
      |> ignore
      col.show(fn() { styling() }, fn(row) { style_row(row) }, at_once=true)
      col.show(fn() { beauty_on.get() }, fn(row) { beauty_row(row) }, at_once=true)
    })
    |> ignore
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
) -> Unit {
  tool_group_button(bar, fn() { glyph_name }, fn() { label }, on, press, dim~, strong~, tip~)
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
) -> Unit {
  // (`tip`: told by the overlay's tip; a button of another window, the long screenshot's panel, is not: the tip is the
  // overlay's, its node ids of no other window)
  bar.box(fn(b) {
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
      if on() {
        0xFFFFFF2EL
      } else if b.pressed() {
        0xFFFFFF24L
      } else if b.pointed() && !dim() {
        0xFFFFFF17L
      } else {
        0L
      }
    }))
    |> ignore
    if tip {
      tip_follows(b, label_fn, @view.Top)
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
        } else if on() {
          0xFFFFFFFFL
        } else {
          0xD9DBE0FFL
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
/// A sub-tool button inside the second row (`28x28`, concentric superellipse `r=9`).
fn sub_tool_button(row : @view.View, which : Tool, shown : () -> Bool, pick : (Tool) -> Unit) -> Unit {
  row.box(fn(b) {
    b
    .laid_nowhere(By(fn() { !shown() }))
    .width(Is(Some(28.0)))
    .height(Is(Some(28.0)))
    .radius(Is(style_btn_corner))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .says(By(fn() { Some(@view.said(Button, label=tr(tool_label(which)))) }))
    .on_press(fn() {
      tip_off()
      pick(which)
    })
    .ground(By(fn() {
      if tool.get() == which {
        0xFFFFFF2EL
      } else if b.pressed() {
        0xFFFFFF24L
      } else if b.pointed() {
        0xFFFFFF17L
      } else {
        0L
      }
    }))
    |> ignore
    tip_follows(b, fn() { tool_label(which) }, @view.Bottom)
    b.box(fn(g) {
      g
      .width(Is(Some(17.0)))
      .height(Is(Some(17.0)))
      .picture(Is(Some(glyph(tool_glyph(which)))))
      .tint(By(fn() { if tool.get() == which { 0xFFFFFFFFL } else { 0xD9DBE0FFL } }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The second row: shape/line sub-tool variants (when a shape or line tool is active), three thicknesses, then the colours.
fn style_row(row : @view.View) -> Unit {
  bar_panel(row, style_corner)
  row.row(Is(true)).height(Is(Some(style_height))).gap(Is(bar_gap)) |> ignore
  // Shape variants: Box, Oval, Focus
  let in_shape = fn() { is_shape_tool(tool.get()) }
  for which in shape_variants {
    sub_tool_button(row, which, in_shape, fn(w) {
      shape_tool.set(w)
      tool.set(w)
    })
  }
  bar_rule_node(row, shown=in_shape)
  // Line variants: Arrow, Line
  let in_line = fn() { is_line_tool(tool.get()) }
  for which in line_variants {
    sub_tool_button(row, which, in_line, fn(w) {
      line_tool.set(w)
      tool.set(w)
    })
  }
  bar_rule_node(row, shown=in_line)
  // Mosaic variants: Mosaic, MosaicBrush, Blur (6-key compact bar: 3 modes + 3 sizes, no colour swatches)
  let in_mosaic = fn() { is_mosaic_tool(tool.get()) }
  for which in mosaic_variants {
    sub_tool_button(row, which, in_mosaic, fn(w) {
      mosaic_tool.set(w)
      tool.set(w)
    })
  }
  bar_rule_node(row, shown=in_mosaic)
  let has_color = fn() {
    let t = tool.get()
    if t != Move {
      !is_mosaic_tool(t) && t != Focus
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
  for s in 0..<3 {
    row.box(fn(b) {
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
      .ground(By(fn() {
        if size_now.get() == s {
          0xFFFFFF2EL
        } else if b.pointed() {
          0xFFFFFF17L
        } else {
          0L
        }
      }))
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
  bar_rule_node(row, shown=has_color)
  for c in colors {
    row.box(fn(b) {
      b
      .laid_nowhere(By(fn() { !has_color() }))
      .width(Is(Some(28.0)))
      .height(Is(Some(28.0)))
      .radius(Is(style_btn_corner))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .presses(Is(true))
      .says(Is(Some(@view.said(Button, label=hex6((c >> 8).to_int())))))
      .on_press(fn() {
        color_now.set(c)
        restyle_selected(c~)
      })
      .ground(By(fn() { if b.pointed() { 0xFFFFFF17L } else { 0L } }))
      |> ignore
      b.box(fn(sw) {
        sw
        .width(Is(Some(16.0)))
        .height(Is(Some(16.0)))
        .radius(Is(5.0))
        .ground(Is(c))
        .edge(By(fn() { if color_now.get() == c { (2.0, 0xFFFFFFFFL) } else { (1.0, 0xFFFFFF33L) } }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  }
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
    _ => lines([])
  }
}

// The bar's tips (the user, 2026-11-20: 「给那些按钮加一个 hover tips，不然我都不知道是什么功能」): what a button does,
// in a small dark label beside it once the pointer has rested on it a moment; from one button to the next while one
// shows, at once. Gone as the pointer leaves or presses.

///|
/// The button pointed at.
let tip_on : @signals.Signal[@view.NodeId?] = @signals.signal(None)

///|
/// What the button pointed at does and the side its tip goes on (set with `tip_on`).
let tip_of : Ref[(() -> String, @view.Side)] = Ref((fn() { "" }, @view.Top))

///|
/// Whether tips show now (the pointer has rested on a button long enough, and not moved off the bar since).
let tip_ready : @signals.Signal[Bool] = @signals.signal(false)

///|
let tip_wait : Double = 450.0

///|
/// How long after leaving a button the next one's tip still shows at once.
let tip_linger : Double = 300.0

///|
fn tip_off() -> Unit {
  tip_on.set(None)
  tip_ready.set(false)
}

///|
/// Button `b` tells what it does (`label`, said through `tr`) by a tip on `side` while it is pointed at.
fn tip_follows(b : @view.View, label : () -> String, side : @view.Side) -> Unit {
  let id = b.id()
  b.reacts(fn() { b.pointed() }, fn(pointed) {
    if pointed {
      tip_of.val = (label, side)
      tip_on.set(Some(id))
      if !tip_ready.untracked() {
        b.at_moment(b.cause_at() + tip_wait, fn() {
          if tip_on.untracked() == Some(id) {
            tip_ready.set(true)
          }
        })
        |> ignore
      }
    } else if tip_on.untracked() == Some(id) {
      tip_on.set(None)
      b.at_moment(b.cause_at() + tip_linger, fn() { if tip_on.untracked() is None { tip_ready.set(false) } }, later=true)
      |> ignore
    }
  })
}

///|
fn bar_tip_node(o : @view.View) -> Unit {
  o.pick(
    fn() {
      if tip_ready.get() {
        tip_on.get()
      } else {
        None
      }
    },
    fn(layer, key) {
      guard key is Some(id) else { return }
      let (label, side) = tip_of.val
      layer.box(fn(t) {
        t
        .beside(id, side~, along=Middle, offset=6.0, padding=4.0)
        .presses(Is(false))
        .points(Is(false))
        .padding(Is((8.0, 4.0, 8.0, 4.0)))
        .radius(Is(7.0))
        .ground(Is(0x1E1F23F7L))
        .edge(Is((1.0, 0xFFFFFF1FL)))
        .shadow(Is((10.0, 2.0, 0x00000059L)))
        |> ignore
        t.box(fn(w) {
          w
          .words(By(fn() { tr(label()) }), look={ ..@view.words_plain, size: 12.0, weight: 500, line: 16.0, wrap: false })
          .ink(Is(0xECEEF2FFL))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    at_once=true,
  )
}
