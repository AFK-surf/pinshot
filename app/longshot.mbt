// A long screenshot (the user, 2026-11-19: 「加一个长截图功能」, the person scrolling and PinShot stitching, as PixPin
// does): the part picked in a capture is taken again and again from the live screen while the person scrolls what is
// under it with the wheel, each new picture laid under the last where they overlap (longshot_win.c), into one tall
// picture. The overlay goes as it begins; a frame round the part shows what is taken, and a panel beside it (a window of
// this run, "long", kept out of what is taken) the picture so far, its size, and what to do with it: copy, save, pin,
// or call it off.

///|
/// A long screenshot begun of the part x, y, w by h (the screen's pixels): 1 begun.
extern "C" fn ps_long_begin(x : Int, y : Int, w : Int, h : Int) -> Int = "ps_long_begin"

///|
/// The taking stopped, the picture kept (its frame gone).
extern "C" fn ps_long_stop() -> Unit = "ps_long_stop"

///|
/// The long screenshot let go, all it held.
extern "C" fn ps_long_end() -> Unit = "ps_long_end"

///|
/// The picture as it stands: "w,h,pictures,lost,full"; "" none.
extern "C" fn ps_long_info() -> Bytes = "ps_long_info"

///|
/// The picture brought down to fit `w` by `h` pixels, as mbui takes pixels kept elsewhere ("MBRAWPTR"...).
extern "C" fn ps_long_preview(w : Int, h : Int) -> Bytes = "ps_long_preview"

///|
/// The picture as a PNG; empty: none.
extern "C" fn ps_long_png() -> Bytes = "ps_long_png"

///|
/// The previews' pixels kept on the native side let go (each forgotten by mbui first).
extern "C" fn ps_long_preview_free() -> Unit = "ps_long_preview_free"

///|
/// Whether a scrolling screenshot can be taken here: Windows' alone (its taking is longshot_win.c's).
fn long_shot_here() -> Bool {
  @hostapi.platform() == 3
}

///|
/// Window `wid` kept out of what is taken (it may stand over the part).
extern "C" fn ps_long_exclude(wid : Int) -> Unit = "ps_long_exclude"

///|
/// The panel's window (0: none, no long screenshot under way).
let long_wid : Ref[Int] = Ref(0)

///|
/// The part taken (the screen's pixels) and its monitor's scale.
let long_part : Ref[Rect] = Ref({ x: 0, y: 0, w: 0, h: 0 })

///|
let long_scale : Ref[Double] = Ref(1.0)

///|
/// The monitor the part is on (the screen's pixels).
let long_mon : Ref[Rect] = Ref({ x: 0, y: 0, w: 0, h: 0 })

///|
/// How tall the picture is (pixels), whether the last picture taken matched none, whether it is as tall as it may be.
let long_h : @signals.Signal[Int] = @signals.signal(0)

///|
let long_lost : @signals.Signal[Bool] = @signals.signal(false)

///|
let long_full : @signals.Signal[Bool] = @signals.signal(false)

///|
/// Whether the taking has stopped (a save's dialog up, called off there: what is taken is kept as it was).
let long_stopped : @signals.Signal[Bool] = @signals.signal(false)

///|
/// The preview shown: its key ("" none) and its size (pixels); and the next, shown once it is decoded.
let long_preview : @signals.Signal[(String, Int, Int)] = @signals.signal(("", 0, 0))

///|
let long_pending : @signals.Signal[(String, Int, Int)] = @signals.signal(("", 0, 0))

///|
/// The panel's tree (None: none open).
let long_root : Ref[@view.View?] = Ref(None)

///|
let long_preview_n : Ref[Int] = Ref(0)

///|
/// When the preview was last made (ps_now_ms), and whether one is due.
let long_preview_at : Ref[Double] = Ref(-10000.0)

///|
let long_preview_due : Ref[Bool] = Ref(false)

///|
/// The panel's width and the preview's room in it (points).
let long_panel_w : Double = 264.0

///|
let long_pad : Double = 14.0

///|
fn long_box_w() -> Double {
  long_panel_w - long_pad * 2.0
}

///|
let long_box_h : Ref[Double] = Ref(360.0)

///|
fn long_panel_h() -> Double {
  long_pad + long_head_h + 4.0 + 16.0 + 12.0 + long_box_h.val + 12.0 + bar_button + long_pad
}

///|
let long_head_h : Double = 22.0

///|
/// The part picked in the capture taken long: the capture closed, the taking begun, the panel put beside the part.
fn long_out() -> Unit {
  if !long_shot_here() || exporting.val != "" || long_wid.val != 0 {
    return
  }
  guard sel.untracked() is Some(r) else { return }
  let m = mon.val
  let k = mon_scale.untracked()
  let part : Rect = { x: m.x + r.x, y: m.y + r.y, w: r.w, h: r.h }
  close_capture()
  if ps_long_begin(part.x, part.y, part.w, part.h) == 0 {
    toast(tr("选区太小，不能长截图"))
    return
  }
  // (no capture taken meanwhile: its overlay would be taken into the picture)
  ps_capture_open(1)
  long_part.val = part
  long_scale.val = k
  long_mon.val = m
  @signals.start_batch()
  long_h.set(0)
  long_lost.set(false)
  long_full.set(false)
  long_stopped.set(false)
  long_preview.set(("", 0, 0))
  long_pending.set(("", 0, 0))
  @signals.end_batch()
  long_preview_due.val = false
  // (the preview as tall as the monitor leaves room for)
  let mh = m.h.to_double() / k
  long_box_h.val = clamp(mh - 48.0 - (long_panel_h() - long_box_h.val), 160.0, 520.0)
  let wid = @ui.window_open_here("long")
  if wid <= 0 {
    log("long: no window")
    ps_long_end()
    ps_capture_open(0)
    return
  }
  long_wid.val = wid
  ps_own(wid, 1) |> ignore
  ps_shadow(wid)
  ps_long_exclude(wid)
  long_place(m)
  log("long: begun \{part.w}x\{part.h} at \{part.x},\{part.y}")
}

///|
/// The panel put beside the part: at its right, else its left, else inside it at its right (out of what is taken
/// whatever it stands over), its top by the part's, kept on the monitor.
fn long_place(m : Rect) -> Unit {
  let k = long_scale.val
  let p = long_part.val
  let w = (long_panel_w * k).round().to_int()
  let h = (long_panel_h() * k).round().to_int()
  let gap = (12.0 * k).round().to_int()
  let x = if p.right() + gap + w <= m.right() {
    p.right() + gap
  } else if p.x - gap - w >= m.x {
    p.x - gap - w
  } else {
    p.right() - gap - w
  }
  let y = clampi(p.y, m.y + gap, m.bottom() - gap - h)
  ps_place(long_wid.val, x, y, w, h, 1, 0)
}

///|
/// What the native side told of the picture ({"do":"long"}): its height, whether the last picture matched.
fn long_told(h : Int, lost : Bool, full : Bool) -> Unit {
  if long_wid.val == 0 {
    return
  }
  @signals.start_batch()
  long_h.set(h)
  long_lost.set(lost)
  long_full.set(full)
  @signals.end_batch()
  long_preview_soon()
}

///|
/// The preview made again, at most every 50 ms: at once where the last is older, else as that time is up.
fn long_preview_soon() -> Unit {
  let since = ps_now_ms() - long_preview_at.val
  if since >= long_preview_ms {
    long_preview_make()
    return
  }
  if long_preview_due.val {
    return
  }
  long_preview_due.val = true
  match long_root.val {
    Some(r) =>
      r.at_moment(r.cause_at() + long_preview_ms - since, fn() {
        long_preview_due.val = false
        if long_wid.val != 0 {
          long_preview_make()
        }
      }, later=true)
      |> ignore
    None => ()
  }
}

///|
let long_preview_ms : Double = 50.0

///|
fn long_preview_make() -> Unit {
  long_preview_at.val = ps_now_ms()
  let k = long_scale.val
  let b = ps_long_preview((long_box_w() * k).round().to_int(), (long_box_h.val * k).round().to_int())
  if b.length() < 28 {
    return
  }
  let pw = le32(b, 16)
  let ph = le32(b, 20)
  long_preview_n.val += 1
  let key = "mem:long/\{long_preview_n.val}"
  @ui.add_image(key, b)
  // (shown only once it is decoded, the one shown kept till then: a picture handed over is nothing till its texture
  // is made, and shown at once it blinked out at every change; one waiting that this one comes before let go)
  let (waiting, _, _) = long_pending.untracked()
  if waiting != "" {
    @ui.forget_image(waiting)
  }
  long_pending.set((key, pw, ph))
  match long_root.val {
    Some(r) => r.image_ask(key, (if pw > ph { pw } else { ph }).to_double())
    None => ()
  }
}

///|
/// The preview decoded: shown in the place of the one before, which is let go.
fn long_preview_shown(key : String) -> Unit {
  let (waiting, pw, ph) = long_pending.untracked()
  if key == "" || key != waiting {
    return
  }
  let (shown, _, _) = long_preview.untracked()
  @signals.start_batch()
  long_pending.set(("", 0, 0))
  long_preview.set((key, pw, ph))
  @signals.end_batch()
  if shown != "" {
    @ui.forget_image(shown)
  }
}

///|
/// The little-endian 32-bit number at `at` of `b`.
fn le32(b : Bytes, at : Int) -> Int {
  b[at].to_int() | (b[at + 1].to_int() << 8) | (b[at + 2].to_int() << 16) | (b[at + 3].to_int() << 24)
}

///|
/// The picture as it stands, its taking stopped: its PNG (None: there is none).
fn long_png() -> Bytes? {
  ps_long_stop()
  long_stopped.set(true)
  let png = ps_long_png()
  if png.length() == 0 {
    None
  } else {
    Some(png)
  }
}

///|
/// The picture's size: (w, h) pixels.
fn long_size() -> (Int, Int) {
  let n = numbers_of(text_of(ps_long_info()))
  if n.length() >= 2 {
    (n[0].to_int(), n[1].to_int())
  } else {
    (0, 0)
  }
}

///|
/// The picture copied (and kept in the pictures' folder where the settings say so), the long screenshot over.
fn long_copy() -> Unit {
  // (nothing taken yet, its first moment: a key pressed then does nothing, rather than close it with nothing)
  if long_h.untracked() == 0 {
    return
  }
  let (w, h) = long_size()
  guard long_png() is Some(png) else {
    long_close()
    return
  }
  shutter()
  let test_to = @ui.env("PINSHOT_TEST_COPY")
  if test_to != "" {
    ps_write_file(cstr(test_to), png) |> ignore
  } else {
    @hostapi.clipboard_set_image(png)
  }
  log("long: copied \{w}x\{h}, \{png.length()} bytes")
  if settings.untracked().keep_copies {
    write_picture_file(file_in(settings.untracked().save_dir, file_name()), png)
  }
  long_close()
}

///|
/// The picture saved (where the settings say to ask, where the system's dialog says), the long screenshot over; the
/// dialog called off, the panel stays, the taking stopped.
fn long_save() -> Unit {
  if long_h.untracked() == 0 {
    return
  }
  guard long_png() is Some(png) else {
    long_close()
    return
  }
  let s = settings.untracked()
  let path = if s.ask_where {
    text_of(ps_save_dialog(long_wid.val, cstr(s.save_dir), cstr(file_name())))
  } else {
    file_in(s.save_dir, file_name())
  }
  if path == "" {
    return
  }
  write_picture_file(path, png)
  shutter()
  log("long: saved \{path}")
  long_close()
}

///|
/// The picture pinned where the part was, as tall as the monitor leaves room for (its zoom brought down to fit), the
/// long screenshot over.
fn long_pin() -> Unit {
  if long_h.untracked() == 0 {
    return
  }
  let (w, h) = long_size()
  guard long_png() is Some(png) else {
    long_close()
    return
  }
  let p = long_part.val
  let m = long_mon.val
  // (its top where the part's was, kept on the monitor: its zoom brought down to what is left under it, 1/4 at least)
  let y = clampi(p.y, m.y, m.y + m.h * 3 / 4)
  let room = (m.bottom() - y).to_double()
  let z = if h.to_double() > room { room / h.to_double() } else { 1.0 }
  shutter()
  long_close()
  open_pin(png, p.x, y, w, h, zoom=z)
}

///|
/// The long screenshot over: the taking stopped, what it held let go, the panel closed.
fn long_close() -> Unit {
  if long_wid.val == 0 {
    return
  }
  ps_long_end()
  ps_capture_open(0)
  let wid = long_wid.val
  long_wid.val = 0
  close_window(wid)
  long_gone()
}

///|
/// The panel's window gone (closed here or by the system): what the long screenshot held let go.
fn long_gone() -> Unit {
  if long_wid.val != 0 {
    long_wid.val = 0
    ps_long_end()
    ps_capture_open(0)
  }
  let (key, _, _) = long_preview.untracked()
  let (waiting, _, _) = long_pending.untracked()
  long_preview.set(("", 0, 0))
  long_pending.set(("", 0, 0))
  long_root.val = None
  for k in [key, waiting] {
    if k != "" {
      @ui.forget_image(k)
    }
  }
  // (their pixels let go only now: mbui reads none of them once they are forgotten)
  ps_long_preview_free()
  trim_soon()
}

///|
/// What the panel says under its title, and the colour of the dot before its title: how to go on, or what went wrong.
fn long_state() -> (String, Int64) {
  if long_stopped.get() {
    (tr("已停止截取"), 0x8C9199FFL)
  } else if long_full.get() {
    (tr("已到最大高度"), 0xF5A524FFL)
  } else if long_lost.get() {
    (tr("没接上，往回滚一点"), 0xF5A524FFL)
  } else if long_h.get() <= long_part.val.h {
    (tr("在框内滚动鼠标滚轮"), 0x4CC38AFFL)
  } else {
    (tr("继续滚动，或点复制完成"), 0x4CC38AFFL)
  }
}

///|
let long_ink : Int64 = 0xEDEEF0FFL

///|
let long_muted : Int64 = 0x9EA3ABFFL

///|
/// The panel's window, made as it opens: dark as the bar is, its corners round (the system's), a title with a dot
/// that says how it goes and the picture's size, a line under it, the picture so far, and what to do with it.
fn long_window(root : @view.View) -> Unit {
  long_root.val = Some(root)
  root.tree.hand_over_presses(false)
  root.reacts(fn() {
    let (key, pw, ph) = long_pending.get()
    if key != "" && root.image_ready(key, (if pw > ph { pw } else { ph }).to_double()) {
      key
    } else {
      ""
    }
  }, long_preview_shown)
  root.keymap(Is(long_keys())) |> ignore
  root.box(fn(page) {
    page
    .over(Is(true))
    .ground(Is(0x1E1F23FFL))
    .padding(Is((long_pad, long_pad, long_pad, long_pad)))
    .lines_up(Is(Some(Start)))
    |> ignore
    // the title: a dot, its name, the picture's size
    page.box(fn(t) {
      t
      .row(Is(true))
      .gap(Is(8.0))
      .height(Is(Some(long_head_h)))
      .width(Is(Some(long_box_w())))
      .lines_up(Is(Some(Middle)))
      |> ignore
      t.box(fn(d) {
        d.width(Is(Some(8.0))).height(Is(Some(8.0))).radius(Is(4.0)).ground(By(fn() { long_state().1 })) |> ignore
      })
      |> ignore
      t.box(fn(l) {
        l
        .grow(Is(1.0))
        .words(By(fn() { tr("长截图") }), look={ ..@view.words_plain, size: 14.0, weight: 600, line: 20.0, wrap: false })
        .ink(Is(long_ink))
        |> ignore
      })
      |> ignore
      t.box(fn(s) {
        s
        .height(Is(Some(long_head_h)))
        .padding(Is((7.0, 0.0, 7.0, 0.0)))
        .radius(Is(5.0))
        .ground(Is(0xFFFFFF12L))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .laid_nowhere(By(fn() { long_h.get() == 0 }))
        |> ignore
        s.box(fn(w) {
          w
          .words(By(fn() { "\{long_part.val.w} × \{long_h.get()}" }), look={
            ..@view.words_plain,
            size: 12.0,
            weight: 500,
            line: 16.0,
            wrap: false,
          })
          .ink(Is(long_ink))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    page.box(fn(g) { g.height(Is(Some(4.0))) |> ignore }) |> ignore
    page.box(fn(t) {
      t
      .height(Is(Some(16.0)))
      .padding(Is((16.0, 0.0, 0.0, 0.0)))
      .words(By(fn() { long_state().0 }), look={ ..@view.words_plain, size: 12.0, weight: 400, line: 16.0, wrap: false })
      .ink(By(fn() { if long_lost.get() || long_full.get() { 0xF5A524FFL } else { long_muted } }))
      |> ignore
    })
    |> ignore
    page.box(fn(g) { g.height(Is(Some(12.0))) |> ignore }) |> ignore
    // the picture's foot at the room's width, what came in last at its foot (all of it while it is shorter, from the
    // room's top)
    page.box(fn(b) {
      b
      .width(Is(Some(long_box_w())))
      .height(Is(Some(long_box_h.val)))
      .radius(Is(8.0))
      .ground(Is(0x121316FFL))
      .edge(Is((1.0, 0xFFFFFF14L)))
      .clips(Is(true))
      .lines_up(Is(Some(Middle)))
      |> ignore
      b.box(fn(i) {
        i
        .width(By(fn() { Some(long_preview.get().1.to_double() / long_scale.val) }))
        .height(By(fn() { Some(long_preview.get().2.to_double() / long_scale.val) }))
        .image(By(fn() {
          let (key, pw, ph) = long_preview.get()
          if key == "" {
            None
          } else {
            Some((key, "", if pw > ph { pw } else { ph }))
          }
        }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    page.box(fn(g) { g.height(Is(Some(12.0))) |> ignore }) |> ignore
    // what to do with it: call it off, pin, save; copy, the one most asked for, apart and lit
    page.box(fn(bar) {
      bar.row(Is(true)).gap(Is(bar_gap)).width(Is(Some(long_box_w()))).lines_up(Is(Some(Middle))) |> ignore
      tool_button(bar, "close", "取消 Esc", fn() { false }, long_close, tip=false)
      tool_button(bar, "pin", "贴到屏幕 Ctrl+T", fn() { false }, long_pin, dim=fn() { long_h.get() == 0 }, tip=false)
      tool_button(bar, "save", "保存 Ctrl+S", fn() { false }, long_save, dim=fn() { long_h.get() == 0 }, tip=false)
      bar.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
      long_copy_button(bar)
    })
    |> ignore
  })
  |> ignore
  let on = fn(name : String, f : () -> Unit) {
    root.on_action(name, fn(_) {
      f()
      true
    })
    |> ignore
  }
  on("close", long_close)
  on("copy", long_copy)
  on("save", long_save)
  on("pin", long_pin)
}

///|
/// The panel's copy: the accent's, its glyph and its name.
fn long_copy_button(bar : @view.View) -> Unit {
  bar.box(fn(b) {
    b
    .row(Is(true))
    .gap(Is(6.0))
    .height(Is(Some(bar_button)))
    .padding(Is((12.0, 0.0, 14.0, 0.0)))
    .radius(Is(7.0))
    .lines_up(Is(Some(Middle)))
    .presses(Is(true))
    .says(By(fn() { Some(@view.said(Button, label=tr("复制 Enter"))) }))
    .on_press(fn() { if long_h.untracked() > 0 { long_copy() } })
    .ground(By(fn() {
      if long_h.get() == 0 {
        0x2F9BFF59L
      } else if b.pressed() {
        0x1F7FDDFFL
      } else if b.pointed() {
        0x48A8FFFFL
      } else {
        accent
      }
    }))
    |> ignore
    b.box(fn(g) {
      g.width(Is(Some(16.0))).height(Is(Some(16.0))).picture(Is(Some(glyph("check")))).tint(Is(0xFFFFFFFFL)) |> ignore
    })
    |> ignore
    b.box(fn(t) {
      t
      .words(By(fn() { tr("复制") }), look={ ..@view.words_plain, size: 13.0, weight: 600, line: 18.0, wrap: false })
      .ink(Is(0xFFFFFFFFL))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn long_keys() -> @view.Keymap {
  let k = fn(code : Int, action : String, mods : Int) -> @view.Binding {
    { keys: [{ code, mods }], action, when: Always }
  }
  let ch = fn(c : Char, action : String, mods : Int) { k(@ui.key_of_char(c), action, mods) }
  @view.Keymap::new([
    k(@ui.key_escape, "close", 0),
    k(@ui.key_code_enter, "copy", 0),
    ch('c', "copy", shortcut_mod()),
    ch('s', "save", shortcut_mod()),
    ch('t', "pin", shortcut_mod()),
  ])
}
