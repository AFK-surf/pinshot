// The tool bar of a part picked: under it at its right edge (over it where the screen has no room under it, inside it
// where it has none over it either), dark whatever the theme, as it lies on a picture of anything. The tools that
// draw marks, undo and redo, then what is done with the part: pin it, save it, close, copy it. A tool chosen shows a
// second row under the first: how thick, and the colours.

///|
let bar_button : Double = 32.0

///|
let bar_pad : Double = 4.0

///|
let bar_rule : Double = 9.0

///|
/// The tools on the bar, in order: what each is, its glyph, its name and key.
let bar_tools : Array[(Tool, String, String)] = [
  (Box, "box", "矩形"),
  (Oval, "oval", "椭圆"),
  (Arrow, "arrow", "箭头"),
  (Pen, "pen", "画笔"),
  (Mosaic, "mosaic", "马赛克"),
  (Number, "number", "序号"),
  (Words, "words", "文字"),
]

///|
fn bar_width() -> Double {
  bar_pad * 2.0 + bar_button * 13.0 + bar_rule * 2.0
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
  match sel.get() {
    Some(r) => {
      let rx1 = r.right().to_double() / k
      let ry0 = r.y.to_double() / k
      let ry1 = r.bottom().to_double() / k
      let w = bar_width()
      let h = bar_height + (if tool.get() != Move { style_height + 4.0 } else { 0.0 })
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
fn toolbar(stage : @view.View) -> Unit {
  stage.box(fn(o) {
    o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
    o.box(fn(col) {
      col
      .gap(Is(4.0))
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
        bar_panel(bar)
        bar.row(Is(true)).width(Is(Some(bar_width()))) |> ignore
        for t in bar_tools {
          let (which, glyph_name, label) = t
          tool_button(bar, glyph_name, label, fn() { tool.get() == which }, fn() {
            if words_open.untracked() is Some(_) {
              commit_words()
            }
            tool.set(if tool.untracked() == which { Move } else { which })
          })
        }
        bar_rule_node(bar)
        tool_button(bar, "undo", "撤销 Ctrl+Z", fn() { false }, fn() { undo() |> ignore }, dim=fn() {
          marks.get() |> ignore
          done_before.val.is_empty()
        })
        tool_button(bar, "redo", "重做 Ctrl+Y", fn() { false }, fn() { redo() |> ignore }, dim=fn() {
          marks.get() |> ignore
          undone.val.is_empty()
        })
        bar_rule_node(bar)
        tool_button(bar, "pin", "贴到屏幕 Ctrl+T", fn() { false }, pin_out)
        tool_button(bar, "save", "保存 Ctrl+S", fn() { false }, save_out)
        tool_button(bar, "close", "关闭 Esc", fn() { false }, close_capture)
        tool_button(bar, "check", "复制 Enter", fn() { false }, copy_out, strong=true)
      })
      |> ignore
      col.show(fn() { tool.get() != Move }, fn(row) { style_row(row) }, at_once=true)
    })
    |> ignore
  })
  |> ignore
}

///|
fn bar_panel(b : @view.View) -> Unit {
  b
  .padding(Is((bar_pad, bar_pad, bar_pad, bar_pad)))
  .radius(Is(9.0))
  .ground(Is(0x1E1F23F7L))
  .edge(Is((1.0, 0xFFFFFF1FL)))
  .shadow(Is((18.0, 4.0, 0x00000073L)))
  .lines_up(Is(Some(Middle)))
  .presses(Is(true))
  .cursor(Is(Some(Arrow)))
  |> ignore
}

///|
fn bar_rule_node(bar : @view.View) -> Unit {
  bar.box(fn(r) {
    r.width(Is(Some(bar_rule))).height(Is(Some(20.0))).lies_along(Is(Middle)).lines_up(Is(Some(Middle))) |> ignore
    r.box(fn(l) { l.width(Is(Some(1.0))).height(Is(Some(18.0))).ground(Is(0xFFFFFF24L)) |> ignore }) |> ignore
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
) -> Unit {
  bar.box(fn(b) {
    b
    .width(Is(Some(bar_button)))
    .height(Is(Some(bar_button)))
    .radius(Is(6.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .says(Is(Some(@view.said(Button, label~))))
    .on_press(fn() { if !dim() { press() } })
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
    b.box(fn(g) {
      g
      .width(Is(Some(18.0)))
      .height(Is(Some(18.0)))
      .picture(Is(Some(glyph(glyph_name))))
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
/// The second row: three thicknesses, then the colours.
fn style_row(row : @view.View) -> Unit {
  bar_panel(row)
  row.row(Is(true)).height(Is(Some(style_height))).gap(Is(2.0)).lies_along(Is(End)) |> ignore
  for s in 0..<3 {
    row.box(fn(b) {
      b
      .width(Is(Some(28.0)))
      .height(Is(Some(28.0)))
      .radius(Is(6.0))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .presses(Is(true))
      .says(Is(Some(@view.said(Button, label=["细", "中", "粗"][s]))))
      .on_press(fn() { size_now.set(s) })
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
      let d = [4.0, 7.0, 11.0][s]
      b.box(fn(dot) {
        dot.width(Is(Some(d))).height(Is(Some(d))).radius(Is(d / 2.0)).ground(Is(0xE6E8ECFFL)) |> ignore
      })
      |> ignore
    })
    |> ignore
  }
  bar_rule_node(row)
  for c in colors {
    row.box(fn(b) {
      b
      .width(Is(Some(28.0)))
      .height(Is(Some(28.0)))
      .radius(Is(6.0))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .presses(Is(true))
      .says(Is(Some(@view.said(Button, label=hex6((c >> 8).to_int())))))
      .on_press(fn() { color_now.set(c) })
      .ground(By(fn() { if b.pointed() { 0xFFFFFF17L } else { 0L } }))
      |> ignore
      b.box(fn(sw) {
        sw
        .width(Is(Some(16.0)))
        .height(Is(Some(16.0)))
        .radius(Is(4.0))
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
    "box" => lines(["M3.5 4.5h11v9h-11z"])
    "oval" => lines([oval_path(2.5, 4.0, 13.0, 10.0)])
    "arrow" => lines(["M4 14 14 4", "M7.5 4H14v6.5"])
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
    "undo" => lines(["M6.5 4 3 7.5 6.5 11", "M3.5 7.5h7a4 4 0 0 1 0 8H8"])
    "redo" => lines(["M11.5 4 15 7.5 11.5 11", "M14.5 7.5h-7a4 4 0 0 0 0 8H10"])
    "pin" => lines(["M7 2.8h4l-.6 4.6 2.6 2.4v1.4H5v-1.4l2.6-2.4z", "M9 11.2v4.3"])
    "save" => lines(["M9 3v8.5", "M5.5 8 9 11.5 12.5 8", "M3.5 13v1.7h11V13"])
    "close" => lines(["M4.5 4.5l9 9", "M13.5 4.5l-9 9"])
    "check" => { w: 18.0, h: 18.0, layers: [stroke_layer("M3.5 9.5 7.3 13.2 14.5 5", 0x000000FFL, 2.0)] }
    "copy" => lines(["M6.5 6.5h8v8h-8z", "M11.5 6.5V3.5h-8v8h3"])
    "top" => lines(["M9 15V5", "M5 9l4-4 4 4", "M4 2.8h10"])
    _ => lines([])
  }
}
