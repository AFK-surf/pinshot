// The magnifier by the pointer while a part is being picked (nothing picked yet, or the part dragged out or resized):
// the pixels round the pointer, 8 points each, a hairline between them, the row and the column through the pointer
// tinted and the pixel under it framed; under them where it is and its colour (C copies it). Laid on whole pixels, the
// squares filling it edge to edge, the lines under them as wide as they are.

///|
let mag_cols : Int = 19

///|
let mag_rows : Int = 13

///|
let mag_cell : Double = 8.0

///|
/// Its padding round the squares and under the lines (points).
let mag_pad : Double = 6.0

///|
fn mag_shown() -> Bool {
  if !capturing.get() || !overlay_seen.get() {
    return false
  }
  match hand.get() {
    Drawing(_, _) | Sizing(_, _, _) => true
    Free => sel.get() is None
    _ => false
  }
}

///|
/// The pixels round the pointer as squares, in points; a line of a pixel (1 / k points) between them.
fn mag_picture() -> @pixels.Vector? {
  if !mag_shown() {
    return None
  }
  let k = mon_scale.get()
  let (px, py) = pointer_px.get()
  let cx = px.to_int()
  let cy = py.to_int()
  let w = mag_cols.to_double() * mag_cell
  let h = mag_rows.to_double() * mag_cell
  let by_color : Map[Int, StringBuilder] = Map([])
  for j in 0..<mag_rows {
    for i in 0..<mag_cols {
      let c = pixel_at(cx + i - mag_cols / 2, cy + j - mag_rows / 2)
      let c = if c < 0 { 0x000000 } else { c }
      let sb = match by_color.get(c) {
        Some(sb) => sb
        None => {
          let sb = StringBuilder()
          by_color[c] = sb
          sb
        }
      }
      sb.write_string(rect_path(i.to_double() * mag_cell, j.to_double() * mag_cell, mag_cell, mag_cell))
    }
  }
  let layers : Array[@pixels.VectorPath] = []
  for c, sb in by_color {
    layers.push(fill_layer(sb.to_string(), (c.to_int64() << 8) | 0xFFL))
  }
  let hair = 1.0 / k
  // (the hairlines between the squares: dark, faint, on whole pixels)
  let grid = StringBuilder()
  for i in 1..<mag_cols {
    grid.write_string(rect_path(i.to_double() * mag_cell, 0.0, hair, h))
  }
  for j in 1..<mag_rows {
    grid.write_string(rect_path(0.0, j.to_double() * mag_cell, w, hair))
  }
  layers.push(fill_layer(grid.to_string(), 0x0000001FL))
  // (the row and the column through the pointer, tinted)
  let mx = (mag_cols / 2).to_double() * mag_cell
  let my = (mag_rows / 2).to_double() * mag_cell
  layers.push(
    fill_layer(
      rect_path(0.0, my, mx, mag_cell) +
      rect_path(mx + mag_cell, my, w - mx - mag_cell, mag_cell) +
      rect_path(mx, 0.0, mag_cell, my) +
      rect_path(mx, my + mag_cell, mag_cell, h - my - mag_cell),
      0x2F9BFF40L,
    ),
  )
  // (the pixel under the pointer: a black ring round a white one, both a pixel wide, just outside its square)
  layers.push(
    fill_layer(
      rect_path(mx - hair * 2.0, my - hair * 2.0, mag_cell + hair * 4.0, mag_cell + hair * 4.0) +
      rect_path(mx - hair, my - hair, mag_cell + hair * 2.0, mag_cell + hair * 2.0),
      0x000000FFL,
      even_odd=true,
    ),
  )
  layers.push(
    fill_layer(
      rect_path(mx - hair, my - hair, mag_cell + hair * 2.0, mag_cell + hair * 2.0) +
      rect_path(mx, my, mag_cell, mag_cell),
      0xFFFFFFFFL,
      even_odd=true,
    ),
  )
  Some({ w, h, layers })
}

///|
fn magnifier(stage : @view.View) -> Unit {
  let w = mag_cols.to_double() * mag_cell
  let h = mag_rows.to_double() * mag_cell
  let bw = w + mag_pad * 2.0
  let bh = h + mag_pad * 2.0 + 44.0
  stage.box(fn(o) {
    o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
    o.box(fn(m) {
      m
      .width(Is(Some(bw)))
      .padding(Is((mag_pad, mag_pad, mag_pad, mag_pad)))
      .gap(Is(6.0))
      .radius(Is(10.0))
      .ground(Is(0x1C1D21F5L))
      .edge(Is((1.0, 0xFFFFFF1FL)))
      .shadow(Is((18.0, 6.0, 0x00000073L)))
      .laid_nowhere(By(fn() { !mag_shown() }))
      .offset(By(fn() {
        let k = mon_scale.get()
        let (sw, sh) = mon_pt()
        let (px, py) = pointer_px.get()
        let x = px / k
        let y = py / k
        let nx = if x + 20.0 + bw <= sw { x + 20.0 } else { x - 20.0 - bw }
        let ny = if y + 24.0 + bh <= sh { y + 24.0 } else { y - 20.0 - bh }
        // (on whole pixels: its squares and hairlines sharp)
        ((nx * k).round() / k, (ny * k).round() / k)
      }))
      |> ignore
      m.box(fn(g) {
        g
        .width(Is(Some(w)))
        .height(Is(Some(h)))
        .radius(Is(5.0))
        .clips(Is(true))
        .picture(By(mag_picture))
        |> ignore
      })
      |> ignore
      // where it is (and the part's size while one is dragged out)
      mag_row(m, fn(row) {
        mag_text(row, fn() {
          let (px, py) = pointer_px.get()
          "\{px.to_int()}, \{py.to_int()}"
        }, 0xE6E8ECFFL)
        row.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
        mag_text(row, fn() {
          match clear_part() {
            Some(r) if sel.get() is Some(_) => "\{r.w} × \{r.h}"
            _ => ""
          }
        }, 0x9EA3ADFFL)
      })
      // its colour: a swatch, its hex, its three numbers
      mag_row(m, fn(row) {
        row.box(fn(sw) {
          sw
          .width(Is(Some(12.0)))
          .height(Is(Some(12.0)))
          .radius(Is(3.0))
          .edge(Is((1.0, 0xFFFFFF40L)))
          .ground(By(fn() {
            let (px, py) = pointer_px.get()
            let c = pixel_at(px.to_int(), py.to_int())
            if c < 0 {
              0L
            } else {
              (c.to_int64() << 8) | 0xFFL
            }
          }))
          |> ignore
        })
        |> ignore
        mag_text(row, fn() {
          let (px, py) = pointer_px.get()
          let c = pixel_at(px.to_int(), py.to_int())
          if c < 0 {
            ""
          } else {
            hex6(c)
          }
        }, 0xE6E8ECFFL)
        row.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
        mag_text(row, fn() {
          let (px, py) = pointer_px.get()
          let c = pixel_at(px.to_int(), py.to_int())
          if c < 0 {
            ""
          } else {
            "\{(c >> 16) & 0xFF}, \{(c >> 8) & 0xFF}, \{c & 0xFF}"
          }
        }, 0x9EA3ADFFL)
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// A line of the magnifier: what `f` puts in it side by side, in its middle.
fn mag_row(parent : @view.View, f : (@view.View) -> Unit) -> Unit {
  parent.box(fn(row) {
    row.row(Is(true)).gap(Is(6.0)).lies_along(Is(Middle)).padding(Is((0.0, 2.0, 0.0, 2.0))) |> ignore
    f(row)
  })
  |> ignore
}

///|
fn mag_text(parent : @view.View, text : () -> String, ink : Int64) -> Unit {
  parent.box(fn(t) {
    t
    .words(By(text), look={ ..@view.words_plain, size: 12.0, weight: 500, line: 16.0, wrap: false })
    .ink(Is(ink))
    |> ignore
  })
  |> ignore
}
