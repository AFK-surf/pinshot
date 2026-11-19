// Effects sample the screenshot and the marks below them in paint order.
///|
#derive(Eq)
struct PaintedMark {
  mark : Mark
  layers : Array[@pixels.VectorPath]?
}

///|
let visible_marks : @signals.Signal[Array[PaintedMark]] = @signals.signal([])

///|
fn ordered_marks() -> Array[Mark] {
  let items = marks.get()
  guard draft.get() is Some(m) else { return items }
  let result = items.copy()
  match hand.get() {
    Dragging(_, _, _, _, i, _, _) => result.insert(i, m)
    _ => result.push(m)
  }
  result
}

///|
/// Draw a crop of the frozen image with exactly the supplied marks (no editing handles).
fn picture_of_layers(
  name : String, key : String, r : Rect, items : Array[PaintedMark], done : (Bytes?) -> Unit,
) -> Unit {
  let k = mon_scale.untracked()
  let (mw, mh) = (mon.val.w.to_double() / k, mon.val.h.to_double() / k)
  let px = dmax(mon.val.w.to_double(), mon.val.h.to_double()).to_int()
  @ui.take_picture(name, r.w.to_double() / k, fn(b) {
    b.height(Is(Some(r.h.to_double() / k))).clips(Is(true)).lines_up(Is(Some(Start))) |> ignore
    b.box(fn(s) {
      s.width(Is(Some(mw))).height(Is(Some(mh))).shrink(Is(0.0))
      .offset(Is((-r.x.to_double() / k, -r.y.to_double() / k))) |> ignore
      s.box(fn(p) { p.over(Is(true)).image(Is(Some((key, "", px)))) |> ignore }) |> ignore
      for item in items {
        s.box(fn(row) { row.over(Is(true)) |> ignore; mark_node(row, item) }) |> ignore
      }
    }) |> ignore
  }, done, scale=k)
}

///|
let preview_revision : Ref[Int] = Ref(0)

///|
let painted_input : Ref[(String, Rect?, Array[Mark], Array[PaintedMark])?] = Ref(None)

///|
fn compose_marks(
  items : Array[Mark], area : Rect?, key : String, purpose : String,
  done : (Array[PaintedMark]?) -> Unit,
) -> Unit {
  let preview = purpose == "preview"
  if preview { preview_revision.val += 1 }
  let revision = preview_revision.val
  let k = mon_scale.untracked()
  let focus = items.filter(fn(m) { m.tool == Focus })
  let output : Array[PaintedMark] = []
  let mut first = 0
  // Unchanged lower layers keep their rendered mosaics while the next mark is dragged.
  if painted_input.val is Some((old_key, old_area, old, painted)) &&
    old_key == key && old_area == area && old.filter(fn(m) { m.tool == Focus }) == focus {
    while first < items.length() && first < old.length() && old[first] == items[first] {
      output.push(painted[first])
      first += 1
    }
  }
  fn paint_from(start : Int) -> Unit {
    for i = start; i < items.length(); i = i + 1 {
      let m = items[i]
      if m.tool == Mosaic && i > 0 && mark_rect(m).within(mon.val.w, mon.val.h) is Some(r) {
        let cell = dmax(2.0, (mosaic_pt(m.size) * k).round()).to_int()
        let x = r.x / cell * cell
        let y = r.y / cell * cell
        let right = clampi((r.right() + cell - 1) / cell * cell, x, mon.val.w)
        let bottom = clampi((r.bottom() + cell - 1) / cell * cell, y, mon.val.h)
        let crop : Rect = { x, y, w: right - x, h: bottom - y }
        picture_of_layers("mosaic-" + purpose, key, crop, output, fn(bytes) {
          if preview && revision != preview_revision.val { return }
          guard frozen_key.untracked() == key && bytes is Some(png) &&
            @pixels.decode_png(png) is Some((w, h, rgba)) && w == crop.w && h == crop.h else {
            done(None)
            return
          }
          let layers = mosaic_layers(m, k, sample=fn(cx, cy, side) {
            cell_mean(rgba, w, h, cx - x, cy - y, side)
          })
          output.push({ mark: m, layers: Some(layers) })
          paint_from(i + 1)
        })
        return
      }
      let layers = if m.tool == Focus && focus.last() == Some(m) {
        Some(focus_layers(focus, area))
      } else {
        None
      }
      output.push({ mark: m, layers, })
    }
    if preview { painted_input.val = Some((key, area, items, output)) }
    done(Some(output))
  }
  paint_from(first)
}


///|
fn cell_mean(rgba : FixedArray[Byte], w : Int, h : Int, left : Int, top : Int, side : Int) -> Int {
  let cols = clampi(w - left, 1, side)
  let rows = clampi(h - top, 1, side)
  let mut red = 0
  let mut green = 0
  let mut blue = 0
  for dy in 0..<rows {
    for dx in 0..<cols {
      let at = ((top + dy) * w + left + dx) * 4
      red += rgba[at].to_int()
      green += rgba[at + 1].to_int()
      blue += rgba[at + 2].to_int()
    }
  }
  let n = rows * cols
  ((red / n) << 16) | ((green / n) << 8) | (blue / n)
}
