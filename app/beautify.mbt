// A capture made ready to show (the user, 2026-11-20: 「只做一键美化背景」, its corners superellipses as the bar's): the
// part picked laid on a background (a gradient, light grey or white: a picture is copied with no clear pixels, so its
// own edge is square), room round it, its own corners rounded and a shadow under it. One button of the bar (B) and one row under it; nothing is made or drawn till it is turned on (the
// backgrounds' pictures made as one is first shown), and a capture starts with it off. What is copied, saved or pinned
// is the picture as it shows; the text read out of it (OCR) is the part's alone.

///|
/// Whether the capture under way is laid on a background.
let beauty_on : @signals.Signal[Bool] = @signals.signal(false)

///|
/// How: which background (`beauty_backs`), how much room round it (`beauty_rooms`), and whether it casts a shadow.
/// Kept across captures and runs (beauty.json beside the settings).
#derive(Eq)
struct Beauty {
  back : Int
  room : Int
  shadow : Bool
}

///|
let beauty : @signals.Signal[Beauty] = @signals.signal({ back: 0, room: 1, shadow: true })

///|
/// The backgrounds: a gradient from the top left to the bottom right through three colours (RGB).
let beauty_backs : Array[(Int, Int, Int)] = [
  (0xFFB27A, 0xFF6F91, 0xA78BFA),
  (0x5EE7DF, 0x6A8DFF, 0xB490CA),
  (0xD4FC79, 0x96E6A1, 0x42C6A5),
  (0x1E2A52, 0x3B2F6B, 0x0F172A),
  (0xF4F5F7, 0xEAECF0, 0xDFE3EA),
  (0xFFFFFF, 0xFFFFFF, 0xFFFFFF),
]

///|
let beauty_back_names : Array[String] = ["晚霞", "海洋", "薄荷", "夜空", "浅灰", "纯白"]

///|
/// The room round the part (points), small to large.
let beauty_rooms : Array[Double] = [24.0, 48.0, 80.0]

///|
/// The part's own corner (points: a superellipse, as mbui draws a radius).
let beauty_corner : Double = 12.0

///|
fn beauty_path() -> String {
  file_in(text_of(ps_data_dir()), "beauty.json")
}

///|
let beauty_read : Ref[Bool] = Ref(false)

///|
/// beauty.json read once, as it is first turned on.
fn beauty_load() -> Unit {
  if beauty_read.val {
    return
  }
  beauty_read.val = true
  guard json_of(text_of(ps_read_file(cstr(beauty_path())))) is Some(Json::Object(o)) else { return }
  let n = fn(k : String, d : Int, most : Int) {
    match o.get(k) {
      Some(Number(v, ..)) => clampi(v.to_int(), 0, most)
      _ => d
    }
  }
  beauty.set({
    back: n("back", 0, beauty_backs.length() - 1),
    room: n("room", 1, beauty_rooms.length() - 1),
    shadow: !(o.get("shadow") is Some(False)),
  })
}

///|
fn beauty_change(f : (Beauty) -> Beauty) -> Unit {
  let b = f(beauty.untracked())
  if b == beauty.untracked() {
    return
  }
  beauty.set(b)
  let o : Map[String, Json] = Map([])
  o["back"] = Json::number(b.back.to_double())
  o["room"] = Json::number(b.room.to_double())
  o["shadow"] = Json::boolean(b.shadow)
  ps_write_file(cstr(beauty_path()), @utf8.encode(Json::object(o).stringify())) |> ignore
}

///|
/// The bar's button (and B): turned on or off for this capture.
fn beauty_toggle() -> Unit {
  if sel.untracked() is None {
    return
  }
  beauty_load()
  beauty_on.set(!beauty_on.untracked())
}

///|
/// The room round the part now, in points (0 off).
fn beauty_room() -> Double {
  if beauty_on.get() {
    beauty_rooms[beauty.get().room]
  } else {
    0.0
  }
}

///|
/// The picture's whole as it will be copied (the part and the room round it), in the monitor's pixels; None where it is
/// off or no part is picked.
fn beauty_frame() -> Rect? {
  guard beauty_on.get() && sel.get() is Some(r) else { return None }
  let p = (beauty_room() * mon_scale.get()).round().to_int()
  Some({ x: r.x - p, y: r.y - p, w: r.w + 2 * p, h: r.h + 2 * p })
}

///|
/// The background `i`'s picture (made as it is first asked for: a small gradient the GPU stretches), "" none.
fn beauty_back_key(i : Int) -> String {
  let (a, b, c) = beauty_backs[i]
  if a < 0 {
    return ""
  }
  let key = "mem:beauty/\{i}"
  if !beauty_made.contains(key) {
    let n = 96
    let px = FixedArray::make(n * n * 4, b'\x00')
    let ch = fn(rgb : Int, shift : Int) { ((rgb >> shift) & 0xFF).to_double() }
    for y in 0..<n {
      for x in 0..<n {
        let t = (x + y).to_double() / (2 * (n - 1)).to_double()
        let (from, to, u) = if t < 0.5 { (a, b, t * 2.0) } else { (b, c, t * 2.0 - 1.0) }
        let at = (y * n + x) * 4
        for s in 0..<3 {
          let shift = 16 - s * 8
          let v = ch(from, shift) + (ch(to, shift) - ch(from, shift)) * u
          px[at + s] = v.round().to_int().to_byte()
        }
        px[at + 3] = b'\xff'
      }
    }
    @ui.add_image(key, shown_bytes(n, n, px))
    beauty_made[key] = true
  }
  key
}

///|
let beauty_made : Map[String, Bool] = Map([])

///|
/// The picture as it will be copied, drawn in `b` (as big as it is, in points): the background, the part's shadow,
/// and the part (`part`, made in a box as big as the part, clipped to its corners). `overlay`: as the overlay shows
/// it, where no background shows as dark grey rather than nothing.
fn beauty_drawn(b : @view.View, w : Double, h : Double, part : (@view.View) -> Unit, overlay~ : Bool) -> Unit {
  let s = beauty.untracked()
  let room = beauty_rooms[s.room]
  let key = beauty_back_key(s.back)
  b.box(fn(back) {
    back.over(Is(true)).clips(Is(true)) |> ignore
    if key != "" {
      back.box(fn(g) { g.over(Is(true)).image(Is(Some((key, "", 96)))) |> ignore }) |> ignore
    } else if overlay {
      back.ground(Is(0x2A2B30FFL)) |> ignore
    }
  })
  |> ignore
  if s.shadow {
    b.box(fn(o) {
      o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
      o.box(fn(sh) {
        sh
        .width(Is(Some(w)))
        .height(Is(Some(h)))
        .offset(Is((room, room)))
        .radius(Is(beauty_corner))
        .ground(Is(0xFFFFFFFFL))
        .shadow(Is((28.0, 10.0, 0x00000059L)))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  }
  b.box(fn(o) {
    o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
    o.box(fn(c) {
      c
      .width(Is(Some(w)))
      .height(Is(Some(h)))
      .offset(Is((room, room)))
      .radius(Is(beauty_corner))
      .clips(Is(true))
      .lines_up(Is(Some(Start)))
      |> ignore
      part(c)
    })
    |> ignore
  })
  |> ignore
}

///|
/// In the overlay, under the marks: the background and the part laid on it, where the picture will be copied. Made again
/// as the part, the background, the room or the shadow change (none of that while it is off).
fn beauty_layer(stage : @view.View) -> Unit {
  stage.box(fn(o) {
    o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
    o.pick(fn() {
      match beauty_frame() {
        Some(f) => Some((f, sel.get(), beauty.get(), frozen_key.get()))
        None => None
      }
    }, fn(b, now) {
      guard now is Some((f, Some(r), _, key)) else { return }
      let k = mon_scale.untracked()
      let (mw, mh) = (mon.val.w.to_double() / k, mon.val.h.to_double() / k)
      let px = dmax(mon.val.w.to_double(), mon.val.h.to_double()).to_int()
      b
      .width(Is(Some(f.w.to_double() / k)))
      .height(Is(Some(f.h.to_double() / k)))
      .offset(Is((f.x.to_double() / k, f.y.to_double() / k)))
      |> ignore
      beauty_drawn(b, r.w.to_double() / k, r.h.to_double() / k, fn(c) {
        c.box(fn(s) {
          s
          .width(Is(Some(mw)))
          .height(Is(Some(mh)))
          .shrink(Is(0.0))
          .offset(Is((-r.x.to_double() / k, -r.y.to_double() / k)))
          |> ignore
          s.box(fn(p) { p.over(Is(true)).image(Is(Some((key, "", px)))) |> ignore }) |> ignore
        })
        |> ignore
      }, overlay=true)
    }, at_once=true)
  })
  |> ignore
}

///|
/// The row under the bar while it is on: the backgrounds, the room, the shadow.
fn beauty_row(row : @view.View) -> Unit {
  bar_panel(row, style_corner)
  row.row(Is(true)).height(Is(Some(style_height))).gap(Is(bar_gap)) |> ignore
  for i, name in beauty_back_names {
    row.box(fn(b) {
      b
      .width(Is(Some(28.0)))
      .height(Is(Some(28.0)))
      .radius(Is(style_btn_corner))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .presses(Is(true))
      .says(By(fn() { Some(@view.said(Radio, label=tr(name), selected=beauty.get().back == i)) }))
      .on_press(fn() {
        tip_off()
        beauty_change(fn(s) { { ..s, back: i } })
      })
      .ground(By(fn() {
        if beauty.get().back == i {
          0xFFFFFF2EL
        } else if b.pointed() {
          0xFFFFFF17L
        } else {
          0L
        }
      }))
      |> ignore
      tip_follows(b, fn() { name }, @view.Bottom)
      b.box(fn(sw) {
        sw.width(Is(Some(18.0))).height(Is(Some(18.0))).radius(Is(6.0)).clips(Is(true)).edge(Is((1.0, 0xFFFFFF33L))) |> ignore
        if beauty_backs[i].0 < 0 {
          // (none: a slash across)
          sw.picture(Is(Some({ w: 18.0, h: 18.0, layers: [stroke_layer("M4 14 14 4", 0xFFFFFFB3L, 1.4)] }))) |> ignore
        } else {
          sw.box(fn(g) {
            g.over(Is(true)).image(By(fn() { Some((beauty_back_key(i), "", 96)) })) |> ignore
          })
          |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  }
  bar_rule_node(row)
  for i, name in ["小", "中", "大"] {
    beauty_word_button(row, name, fn() { beauty.get().room == i }, fn() { beauty_change(fn(s) { { ..s, room: i } }) })
  }
  bar_rule_node(row)
  beauty_word_button(row, "阴影", fn() { beauty.get().shadow }, fn() {
    beauty_change(fn(s) { { ..s, shadow: !s.shadow } })
  })
}

///|
fn beauty_word_button(row : @view.View, name : String, on : () -> Bool, press : () -> Unit) -> Unit {
  row.box(fn(b) {
    b
    .height(Is(Some(28.0)))
    .padding(Is((9.0, 0.0, 9.0, 0.0)))
    .radius(Is(style_btn_corner))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .says(By(fn() { Some(@view.said(Button, label=tr(name))) }))
    .on_press(fn() {
      tip_off()
      press()
    })
    .ground(By(fn() {
      if on() {
        0xFFFFFF2EL
      } else if b.pointed() {
        0xFFFFFF17L
      } else {
        0L
      }
    }))
    |> ignore
    b.box(fn(t) {
      t
      .words(By(fn() { tr(name) }), look={ ..@view.words_plain, size: 12.0, weight: 500, line: 16.0, wrap: false })
      .ink(By(fn() { if on() { 0xFFFFFFFFL } else { 0xFFFFFFB3L } }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The picture as it will be copied where the part is laid on a background, else `r`.
fn beauty_or(r : Rect?) -> Rect? {
  match beauty_frame() {
    Some(f) => Some(f)
    None => r
  }
}
