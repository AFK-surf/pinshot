// The magnifier by the pointer while a part is being picked (nothing picked yet, or the part dragged out or resized):
// the pixels round the pointer, 8 points each, the one under it framed; where it is, and its colour (C copies it).

///|
let mag_cols : Int = 15

///|
let mag_rows : Int = 11

///|
let mag_cell : Double = 8.0

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
/// The pixels round the pointer as squares, the one under it framed.
fn mag_picture() -> @pixels.Vector? {
  if !mag_shown() {
    return None
  }
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
  // (a faint cross through the middle, the pixel under the pointer framed black and white)
  let mx = (mag_cols / 2).to_double() * mag_cell
  let my = (mag_rows / 2).to_double() * mag_cell
  layers.push(fill_layer(rect_path(0.0, my, w, mag_cell) + rect_path(mx, 0.0, mag_cell, h), 0x2F9BFF33L))
  layers.push(stroke_layer(rect_path(mx + 0.5, my + 0.5, mag_cell - 1.0, mag_cell - 1.0), 0xFFFFFFFFL, 1.0))
  layers.push(stroke_layer(rect_path(mx - 0.5, my - 0.5, mag_cell + 1.0, mag_cell + 1.0), 0x000000FFL, 1.0))
  Some({ w, h, layers })
}

///|
fn magnifier(stage : @view.View) -> Unit {
  let w = mag_cols.to_double() * mag_cell
  let h = mag_rows.to_double() * mag_cell
  stage.box(fn(o) {
    o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
    o.box(fn(m) {
      m
      .min_width(Is(Some(w + 8.0)))
      .padding(Is((4.0, 4.0, 4.0, 6.0)))
      .gap(Is(4.0))
      .radius(Is(8.0))
      .ground(Is(0x1E1F23F2L))
      .edge(Is((1.0, 0xFFFFFF1FL)))
      .shadow(Is((16.0, 4.0, 0x00000066L)))
      .laid_nowhere(By(fn() { !mag_shown() }))
      .offset(By(fn() {
        let k = mon_scale.get()
        let (sw, sh) = mon_pt()
        let (px, py) = pointer_px.get()
        let x = px / k
        let y = py / k
        let bw = w + 8.0
        let bh = h + 50.0
        let nx = if x + 20.0 + bw <= sw { x + 20.0 } else { x - 20.0 - bw }
        let ny = if y + 24.0 + bh <= sh { y + 24.0 } else { y - 20.0 - bh }
        (nx, ny)
      }))
      |> ignore
      m.box(fn(g) {
        g.width(Is(Some(w))).height(Is(Some(h))).radius(Is(4.0)).clips(Is(true)).picture(By(mag_picture)) |> ignore
      })
      |> ignore
      mag_line(m, fn() {
        let (px, py) = pointer_px.get()
        "\{px.to_int()}, \{py.to_int()}" +
        (match clear_part() {
          Some(r) if sel.get() is Some(_) => "   \{r.w} × \{r.h}"
          _ => ""
        })
      })
      mag_line(m, fn() {
        let (px, py) = pointer_px.get()
        let c = pixel_at(px.to_int(), py.to_int())
        if c < 0 {
          ""
        } else {
          "\{hex6(c)}  \{(c >> 16) & 0xFF}, \{(c >> 8) & 0xFF}, \{c & 0xFF}"
        }
      })
    })
    |> ignore
  })
  |> ignore
}

///|
fn mag_line(parent : @view.View, text : () -> String) -> Unit {
  parent.box(fn(t) {
    t
    .padding(Is((4.0, 0.0, 4.0, 0.0)))
    .words(By(text), look={ ..@view.words_plain, size: 11.5, weight: 500, line: 16.0, wrap: false })
    .ink(Is(0xDADDE2FFL))
    |> ignore
  })
  |> ignore
}
