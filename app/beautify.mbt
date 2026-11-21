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
/// (and the last, the desktop's own wallpaper: `beauty_wall`)
let beauty_back_names : Array[String] = ["晚霞", "海洋", "薄荷", "夜空", "浅灰", "纯白", "桌面壁纸"]

///|
/// The background that is the desktop's wallpaper (the user, 2026-11-20: 「背景是不是可以选用用户自己的背景」).
let beauty_wall : Int = 6

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
    back: n("back", 0, beauty_back_names.length() - 1),
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
  if beauty_on.untracked() {
    wallpaper_read()
    // (the background comes in as its room opens: shown.mbt)
    match overlay_root.val {
      Some(root) => {
        beauty_fade.put(0.0)
        beauty_fade.go(1.0, shown_spring, at=root.cause_at())
      }
      None => ()
    }
  }
}

// ---- the desktop's wallpaper as a background ----

///|
/// The wallpaper as it was read as the background was last turned on: its picture's key and its size (pixels), None
/// where there is none PinShot can show (a colour alone, a file it cannot tell the size of).
let wallpaper : @signals.Signal[(String, Double, Double)?] = @signals.signal(None)

///|
let wallpaper_n : Ref[Int] = Ref(0)

///|
/// The desktop's wallpaper read again (it may have changed since), the one read before let go.
fn wallpaper_read() -> Unit {
  wallpaper_let_go()
  let path = text_of(ps_wallpaper())
  if path == "" {
    return
  }
  let bytes = ps_read_file(cstr(path))
  guard picture_size(bytes) is Some((w, h)) else {
    log("background: the wallpaper \{path} is not a picture PinShot reads")
    return
  }
  wallpaper_n.val += 1
  let key = "mem:beauty/wall/\{wallpaper_n.val}"
  @ui.add_image(key, bytes)
  wallpaper.set(Some((key, w.to_double(), h.to_double())))
}

///|
/// The wallpaper's picture let go (the capture closed): nothing of it kept between captures.
fn wallpaper_let_go() -> Unit {
  match wallpaper.untracked() {
    Some((key, _, _)) => {
      @ui.forget_image(key)
      wallpaper.set(None)
    }
    None => ()
  }
}

///|
/// A PNG's, JPEG's or BMP's size (pixels) as its head says it.
fn picture_size(b : Bytes) -> (Int, Int)? {
  let n = b.length()
  let u = fn(i : Int) { if i < n { b[i].to_int() } else { 0 } }
  let be16 = fn(i : Int) { (u(i) << 8) | u(i + 1) }
  let be32 = fn(i : Int) { (u(i) << 24) | (u(i + 1) << 16) | (u(i + 2) << 8) | u(i + 3) }
  let le32 = fn(i : Int) { u(i) | (u(i + 1) << 8) | (u(i + 2) << 16) | (u(i + 3) << 24) }
  if n > 24 && u(0) == 0x89 && u(1) == 0x50 && u(2) == 0x4E && u(3) == 0x47 {
    return Some((be32(16), be32(20)))
  }
  if n > 26 && u(0) == 0x42 && u(1) == 0x4D {
    let h = le32(22)
    return Some((le32(18), if h < 0 { -h } else { h }))
  }
  if n > 4 && u(0) == 0xFF && u(1) == 0xD8 {
    // (the segments walked to the frame's head: SOF0-SOF15, not DHT C4, JPG C8 or DAC CC)
    let mut i = 2
    while i + 9 < n {
      if u(i) != 0xFF {
        i += 1
        continue
      }
      let m = u(i + 1)
      if m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC {
        return Some((be16(i + 7), be16(i + 5)))
      }
      if m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) || m == 0xFF {
        i += if m == 0xFF { 1 } else { 2 }
        continue
      }
      i += 2 + be16(i + 2)
    }
  }
  None
}

///|
/// A picture `pw` × `ph` (pixels) laid in `box` to cover all of it (`w` × `h`, points), as large as it must be and
/// centred: none of the box left bare, the picture never stretched.
fn covered(
  box : @view.View,
  key : String,
  pw : Double,
  ph : Double,
  w : Double,
  h : Double,
  max_px? : Int = 2560,
) -> Unit {
  let k = dmax(w / pw, h / ph)
  let (cw, ch) = (pw * k, ph * k)
  box.box(fn(o) {
    o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
    o.box(fn(g) {
      g
      .width(Is(Some(cw)))
      .height(Is(Some(ch)))
      .shrink(Is(0.0))
      .offset(Is(((w - cw) / 2.0, (h - ch) / 2.0)))
      .image(Is(Some((key, "", max_px))))
      |> ignore
    })
    |> ignore
  })
  |> ignore
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
  if i >= beauty_backs.length() {
    return ""
  }
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
  let wall = if s.back == beauty_wall { wallpaper.untracked() } else { None }
  // (the wallpaper chosen and none to be had: the first gradient)
  let key = beauty_back_key(if s.back == beauty_wall { 0 } else { s.back })
  b.box(fn(back) {
    back.over(Is(true)).clips(Is(true)) |> ignore
    match wall {
      Some((wk, pw, ph)) => covered(back, wk, pw, ph, w + 2.0 * room, h + 2.0 * room)
      None =>
        if key != "" {
          back.box(fn(g) { g.over(Is(true)).image(Is(Some((key, "", 96)))) |> ignore }) |> ignore
        } else if overlay {
          back.ground(Is(0x2A2B30FFL)) |> ignore
        }
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
    // (made again only as what it draws changes: the part's size, the background, the room, the shadow, the picture;
    // the part moved, it is only moved, its offsets bound, not the whole of it made again at each pixel)
    o.pick(fn() {
      match (beauty_frame(), sel.get()) {
        (Some(f), Some(r)) => Some((f.w, f.h, r.w, r.h, beauty.get(), frozen_key.get(), wallpaper.get()))
        _ => None
      }
    }, fn(b, now) {
      guard now is Some((fw, fh, rw, rh, _, key, _)) else { return }
      let k = mon_scale.untracked()
      let (mw, mh) = (mon.val.w.to_double() / k, mon.val.h.to_double() / k)
      let px = dmax(mon.val.w.to_double(), mon.val.h.to_double()).to_int()
      b
      .alpha(By(fn() { beauty_fade.shown_on(b) }))
      .width(Is(Some(fw.to_double() / k)))
      .height(Is(Some(fh.to_double() / k)))
      .offset(By(fn() {
        match beauty_frame() {
          Some(f) => (f.x.to_double() / k, f.y.to_double() / k)
          None => (0.0, 0.0)
        }
      }))
      |> ignore
      beauty_drawn(b, rw.to_double() / k, rh.to_double() / k, fn(c) {
        c.box(fn(s) {
          s
          .width(Is(Some(mw)))
          .height(Is(Some(mh)))
          .shrink(Is(0.0))
          .offset(By(fn() {
            match sel.get() {
              Some(r) => (-r.x.to_double() / k, -r.y.to_double() / k)
              None => (0.0, 0.0)
            }
          }))
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
/// The row under the bar while it is on: the backgrounds, the room, the shadow (with gliding thumbs & tactile feel).
fn beauty_row(row : @view.View) -> Unit {
  bar_panel(row, style_corner)
  row.row(Is(true)).height(Is(Some(style_height))).gap(Is(bar_gap)) |> ignore
  row.box(fn(bgs) {
    bgs.row(Is(true)).gap(Is(bar_gap)).lines_up(Is(Some(Middle))) |> ignore
    let bg_views : Map[Int, @view.View] = Map([])
    sliding_thumb(
      bgs,
      fn() { beauty.get().back },
      bg_views,
      style_btn_corner,
      fn() { 0xFFFFFF3DL },
      extra_watch=fn() { if wallpaper.get() is Some(_) { 1 } else { 0 } },
    )
    for i, name in beauty_back_names {
      bgs.box(fn(b) {
        bg_views[i] = b
        let hov = smooth_hover(b, ms=100.0)
        tactile_press(b, sink_px=0.9)
        b
        // (the wallpaper's only where there is one to be had)
        .laid_nowhere(By(fn() { i == beauty_wall && wallpaper.get() is None }))
        .width(Is(Some(28.0)))
        .height(Is(Some(28.0)))
        .radius(Is(style_btn_corner))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .presses(Is(true))
        .cursor(Is(Some(Hand)))
        .says(By(fn() { Some(@view.said(Radio, label=tr(name), selected=beauty.get().back == i)) }))
        .on_press(fn() {
          tip_off()
          beauty_change(fn(s) { { ..s, back: i } })
        })
        .ground(By(fn() {
          if beauty.get().back == i {
            0L
          } else {
            mix_rgba(0L, 0xFFFFFF20L, hov())
          }
        }))
        |> ignore
        tip_follows(b, fn() { name }, @view.Bottom)
        b.box(fn(sw) {
          let on_bg = @motion.eased_on(sw, fn() { beauty.get().back == i }, @motion.tween(120.0, ease=Out))
          sw
          .width(Is(Some(18.0)))
          .height(Is(Some(18.0)))
          .radius(Is(6.0))
          .clips(Is(true))
          .scale(By(fn() { 1.0 + 0.06 * on_bg.shown(sw) }))
          .edge(By(fn() {
            let p = on_bg.shown(sw)
            (1.0 + 0.5 * p, mix_rgba(0xFFFFFF33L, 0xFFFFFFFFL, p))
          }))
          |> ignore
          if i == beauty_wall {
            // (the wallpaper as it was read this capture, a little of it)
            sw.pick(fn() { wallpaper.get() }, fn(c, wall) {
              c.width(Is(Some(18.0))).height(Is(Some(18.0))) |> ignore
              match wall {
                // (an 18-point swatch: the picture decoded small for it, not at 2560 pixels)
                Some((key, pw, ph)) => covered(c, key, pw, ph, 18.0, 18.0, max_px=96)
                None => ()
              }
            }, at_once=true)
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
  })
  |> ignore
  bar_rule_node(row)
  row.box(fn(rooms) {
    rooms.row(Is(true)).gap(Is(bar_gap)).lines_up(Is(Some(Middle))) |> ignore
    let rm_views : Map[Int, @view.View] = Map([])
    sliding_thumb(rooms, fn() { beauty.get().room }, rm_views, style_btn_corner, fn() { 0xFFFFFF3DL })
    for i, name in ["小", "中", "大"] {
      beauty_word_button(
        rooms,
        name,
        fn() { beauty.get().room == i },
        fn() { beauty_change(fn(s) { { ..s, room: i } }) },
        slot_views=Some((i, rm_views)),
      )
    }
  })
  |> ignore
  bar_rule_node(row)
  beauty_word_button(row, "阴影", fn() { beauty.get().shadow }, fn() {
    beauty_change(fn(s) { { ..s, shadow: !s.shadow } })
  })
}

///|
fn beauty_word_button(
  row : @view.View,
  name : String,
  on : () -> Bool,
  press : () -> Unit,
  slot_views? : (Int, Map[Int, @view.View])? = None,
) -> Unit {
  row.box(fn(b) {
    let has_slider = match slot_views {
      Some((idx, views)) => {
        views[idx] = b
        true
      }
      None => false
    }
    let hov = smooth_hover(b, ms=100.0)
    let act = @motion.eased_on(b, on, @motion.tween(120.0, ease=Out))
    tactile_press(b, sink_px=0.9)
    b
    .height(Is(Some(28.0)))
    .padding(Is((9.0, 0.0, 9.0, 0.0)))
    .radius(Is(style_btn_corner))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .cursor(Is(Some(Hand)))
    .says(By(fn() { Some(@view.said(Button, label=tr(name))) }))
    .on_press(fn() {
      tip_off()
      press()
    })
    .ground(By(fn() {
      if has_slider && on() {
        0L
      } else {
        let rest = mix_rgba(0L, 0xFFFFFF20L, hov())
        if has_slider { rest } else { mix_rgba(rest, 0xFFFFFF3DL, act.shown(b)) }
      }
    }))
    |> ignore
    b.box(fn(t) {
      t
      .words(By(fn() { tr(name) }), look={ ..@view.words_plain, size: 12.0, weight: 500, line: 16.0, wrap: false })
      .ink(By(fn() { mix_rgba(0xD8DCE4FFL, 0xFFFFFFFFL, dmax(act.shown(t), hov() * 0.5)) }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}
