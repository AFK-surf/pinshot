// The magnifier by the pointer while a part is being picked (nothing picked yet, or the part dragged out or resized):
// the pixels round the pointer, 8 points each, a hairline between them, the row and the column through the pointer
// tinted and the pixel under it framed; under them a tag: where it is, and its colour (C copies it). Its look the
// user's pick of three made for it (2026-11-17, C: 「极简格子 + 标签」): no panel, the squares alone in a white and a
// black hairline round them, their corners round, a shadow under; the tag as wide as they are, in two parts, the
// accent's and a dark one, its corners as round. Every edge of it on a whole pixel (a pixel is 1 / k points): its
// place, its sizes, its lines.

///|
let mag_cols : Int = 19

///|
let mag_rows : Int = 13

///|
let mag_cell : Double = 8.0

///|
/// Superellipse corner radii (points, matching PinShot's toolbar superellipse language).
let mag_corner : Double = 11.0

///|
let mag_tag_corner : Double = 8.0

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
/// The squares and crosshair (drawn inside a GPU-clipped mbui superellipse frame).
fn mag_picture() -> @pixels.Vector? {
  if !mag_shown() {
    return None
  }
  let k = mon_scale.get()
  let hair = 1.0 / k
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
  // (the hairlines between the squares: dark, faint)
  let grid = StringBuilder()
  for i in 1..<mag_cols {
    grid.write_string(rect_path(i.to_double() * mag_cell, 0.0, hair, h))
  }
  for j in 1..<mag_rows {
    grid.write_string(rect_path(0.0, j.to_double() * mag_cell, w, hair))
  }
  layers.push(fill_layer(grid.to_string(), 0x00000014L))
  // (the row and the column through the pointer, tinted)
  let mx = (mag_cols / 2).to_double() * mag_cell
  let my = (mag_rows / 2).to_double() * mag_cell
  layers.push(
    fill_layer(
      rect_path(0.0, my, mx, mag_cell) +
      rect_path(mx + mag_cell, my, w - mx - mag_cell, mag_cell) +
      rect_path(mx, 0.0, mag_cell, my) +
      rect_path(mx, my + mag_cell, mag_cell, h - my - mag_cell),
      0x2F9BFF52L,
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
  // (outer frame adds 2px on each side: 1px outer dark superellipse rim + 1px inner white superellipse rim)
  let fw = fn() { w + 4.0 / mon_scale.get() }
  let fh = fn() { h + 4.0 / mon_scale.get() }
  let tag_h = 22.0
  let gap = 5.0
  stage.box(fn(o) {
    o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
    o.box(fn(m) {
      m
      .gap(Is(gap))
      .lines_up(Is(Some(Start)))
      .laid_nowhere(By(fn() { !mag_shown() }))
      .offset(By(fn() {
        let k = mon_scale.get()
        let (sw, sh) = mon_pt()
        let (px, py) = pointer_px.get()
        let x = px / k
        let y = py / k
        let bw = fw()
        let bh = fh() + gap + tag_h
        let nx = if x + 20.0 + bw <= sw { x + 20.0 } else { x - 20.0 - bw }
        let ny = if y + 24.0 + bh <= sh { y + 24.0 } else { y - 20.0 - bh }
        // (on whole pixels: its squares, hairlines and edges sharp)
        ((nx * k).round() / k, (ny * k).round() / k)
      }))
      |> ignore
      // Outer superellipse frame + shadow, concentric inner white superellipse rim clipping the pixel grid
      m.box(fn(g) {
        g
        .width(By(fn() { Some(fw()) }))
        .height(By(fn() { Some(fh()) }))
        .radius(Is(mag_corner))
        .ground(Is(0x000000B3L))
        .shadow(Is((14.0, 5.0, 0x00000059L)))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        |> ignore
        g.box(fn(rim) {
          rim
          .width(By(fn() { Some(w + 2.0 / mon_scale.get()) }))
          .height(By(fn() { Some(h + 2.0 / mon_scale.get()) }))
          .radius(By(fn() { mag_corner - 1.0 / mon_scale.get() }))
          .ground(Is(0xFFFFFFFFL))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          |> ignore
          rim.box(fn(pix) {
            pix
            .width(Is(Some(w)))
            .height(Is(Some(h)))
            .radius(By(fn() { mag_corner - 2.0 / mon_scale.get() }))
            .clips(Is(true))
            .picture(By(mag_picture))
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // the tag, as wide as they are, with matching mbui superellipse corners
      m.box(fn(tag) {
        tag
        .row(Is(true))
        .width(By(fn() { Some(fw()) }))
        .height(Is(Some(tag_h)))
        .radius(Is(mag_tag_corner))
        .clips(Is(true))
        .shadow(Is((10.0, 3.0, 0x00000040L)))
        |> ignore
        tag.box(fn(l) {
          // (half of it, its words in the middle: where it splits stays put as the numbers change)
          l
          .row(Is(true))
          .width(By(fn() { Some((fw() * mon_scale.get() / 2.0).round() / mon_scale.get()) }))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          .ground(Is(accent))
          |> ignore
          mag_text(l, fn() {
            // (the part's size while one is dragged out, else where the pointer is)
            match clear_part() {
              Some(r) if sel.get() is Some(_) => "\{r.w} × \{r.h}"
              _ => {
                let (px, py) = pointer_px.get()
                "\{px.to_int()}, \{py.to_int()}"
              }
            }
          }, 0xFFFFFFFFL)
        })
        |> ignore
        tag.box(fn(r) {
          r
          .row(Is(true))
          .grow(Is(1.0))
          .gap(Is(5.0))
          .lines_up(Is(Some(Middle)))
          .padding(Is((7.0, 0.0, 7.0, 0.0)))
          .ground(Is(0x1A1B1FF2L))
          |> ignore
          r.box(fn(sw) {
            sw
            .width(Is(Some(10.0)))
            .height(Is(Some(10.0)))
            .radius(Is(3.0))
            .edge(By(fn() { (1.0 / mon_scale.get(), 0xFFFFFF73L) }))
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
          mag_text(r, fn() {
            let (px, py) = pointer_px.get()
            let c = pixel_at(px.to_int(), py.to_int())
            if c < 0 {
              ""
            } else {
              hex6(c)
            }
          }, 0xECEEF2FFL)
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn mag_text(parent : @view.View, text : () -> String, ink : Int64) -> Unit {
  parent.box(fn(t) {
    t
    .words(By(text), look={ ..@view.words_plain, size: 11.0, weight: 600, line: 14.0, wrap: false })
    .ink(Is(ink))
    |> ignore
  })
  |> ignore
}
