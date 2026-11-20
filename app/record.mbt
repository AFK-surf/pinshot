// Lightweight area screen recorder (Windows): picks a region in the frozen overlay (or Ctrl+R), closes the overlay,
// shows a click-through border frame outside the region, and opens a compact dark floating control bar excluded from
// capture. Encodes silent MP4 (optimal cascade: HW HEVC with hvc1 tag -> HW H.264 -> SW H.264) or animated GIF
// (adaptive palette + dirty-rect delta + LZW), saves into the screenshots folder, and copies the file (CF_HDROP) to
// the clipboard for one-paste sharing.

///|
extern "C" fn ps_rec_prepare(x : Int, y : Int, w : Int, h : Int) -> Int = "ps_rec_prepare"

///|
extern "C" fn ps_rec_rect() -> Bytes = "ps_rec_rect"

///|
#borrow(path)
extern "C" fn ps_rec_start(path : Bytes, fmt : Int, fps : Int, cursor : Int) -> Int = "ps_rec_start"

///|
extern "C" fn ps_rec_pause(on : Int) -> Unit = "ps_rec_pause"

///|
extern "C" fn ps_rec_stop(cancel : Int) -> Unit = "ps_rec_stop"

///|
extern "C" fn ps_rec_end() -> Unit = "ps_rec_end"

///|
extern "C" fn ps_rec_exclude(wid : Int) -> Unit = "ps_rec_exclude"

///|
/// Screen recording is Windows-only for now (record_win.cpp); macOS keeps C stubs.
fn rec_here() -> Bool {
  @hostapi.platform() == 3
}

///|
/// Recording floating bar window id (0: not open).
let rec_wid : Ref[Int] = Ref(0)

///|
let rec_root : Ref[@view.View?] = Ref(None)

///|
let rec_part : Ref[Rect] = Ref({ x: 0, y: 0, w: 0, h: 0 })

///|
let rec_mon : Ref[Rect] = Ref({ x: 0, y: 0, w: 0, h: 0 })

///|
let rec_scale : Ref[Double] = Ref(1.0)

///|
/// Phase: 0 Ready, 1 Recording, 2 Paused, 3 Saving, 4 Done, 5 Error.
let rec_phase : @signals.Signal[Int] = @signals.signal(0)

///|
/// Format: 0 MP4, 1 GIF (remembered across recordings in this session).
let rec_fmt : @signals.Signal[Int] = @signals.signal(0)

///|
/// Target FPS per format.
let rec_fps_mp4 : @signals.Signal[Int] = @signals.signal(30)

///|
let rec_fps_gif : @signals.Signal[Int] = @signals.signal(15)

///|
/// Whether the mouse cursor is captured (default true).
let rec_cursor : @signals.Signal[Bool] = @signals.signal(true)

///|
/// Live stats from the native worker thread.
let rec_ms : @signals.Signal[Int] = @signals.signal(0)

///|
let rec_frames : @signals.Signal[Int] = @signals.signal(0)

///|
let rec_bytes : @signals.Signal[Double] = @signals.signal(0.0)

///|
let rec_codec : @signals.Signal[String] = @signals.signal("")

///|
let rec_path : @signals.Signal[String] = @signals.signal("")

///|
let rec_err : @signals.Signal[String] = @signals.signal("")

///|
/// Generation counter to cancel stale auto-close timers.
let rec_done_gen : @signals.Signal[Int] = @signals.signal(0)

///|
let rec_bar_w : Double = 448.0

///|
let rec_bar_h : Double = 44.0

///|
fn rec_current_fps() -> Int {
  if rec_fmt.get() == 0 {
    rec_fps_mp4.get()
  } else {
    rec_fps_gif.get()
  }
}

///|
fn rec_cycle_fps() -> Unit {
  if rec_fmt.untracked() == 0 {
    rec_fps_mp4.set(if rec_fps_mp4.untracked() == 30 { 60 } else { 30 })
  } else {
    let cur = rec_fps_gif.untracked()
    rec_fps_gif.set(if cur == 15 { 10 } else if cur == 10 { 20 } else { 15 })
  }
}

///|
/// Open the lightweight screen recorder for the current overlay selection.
fn rec_out() -> Unit {
  if !rec_here() || exporting.val != "" || long_wid.val != 0 || rec_wid.val != 0 {
    return
  }
  guard sel.untracked() is Some(r) else { return }
  let m = mon.val
  let k = mon_scale.untracked()
  let rx = m.x + r.x
  let ry = m.y + r.y
  close_capture()
  if ps_rec_prepare(rx, ry, r.w, r.h) == 0 {
    toast(tr("选区太小，不能录屏"))
    return
  }
  let nums = numbers_of(text_of(ps_rec_rect()))
  let part : Rect = if nums.length() >= 4 {
    { x: nums[0].to_int(), y: nums[1].to_int(), w: nums[2].to_int(), h: nums[3].to_int() }
  } else {
    { x: rx, y: ry, w: r.w, h: r.h }
  }
  ps_capture_open(1)
  rec_part.val = part
  rec_mon.val = m
  rec_scale.val = k
  @signals.start_batch()
  rec_phase.set(0)
  rec_ms.set(0)
  rec_frames.set(0)
  rec_bytes.set(0.0)
  rec_codec.set("")
  rec_path.set("")
  rec_err.set("")
  @signals.end_batch()
  let wid = @ui.window_open_here("rec")
  if wid <= 0 {
    log("rec: no window")
    ps_rec_end()
    ps_capture_open(0)
    return
  }
  rec_wid.val = wid
  ps_own(wid, 1) |> ignore
  ps_shadow(wid)
  ps_rec_exclude(wid)
  rec_place(m)
  log("rec: ready \{part.w}x\{part.h} at \{part.x},\{part.y}")
}

///|
/// Position the floating control bar below the region (or above / inside if near the bottom edge).
fn rec_place(m : Rect) -> Unit {
  let k = rec_scale.val
  let p = rec_part.val
  let w = (rec_bar_w * k).round().to_int()
  let h = (rec_bar_h * k).round().to_int()
  let gap = (10.0 * k).round().to_int()
  let x = clampi(p.x + (p.w - w) / 2, m.x + gap, m.right() - gap - w)
  let y = if p.bottom() + gap + h <= m.bottom() - gap {
    p.bottom() + gap
  } else if p.y - gap - h >= m.y + gap {
    p.y - gap - h
  } else {
    p.bottom() - gap - h
  }
  ps_place(rec_wid.val, x, y, w, h, 1, 1)
}

///|
fn rec_output_path(fmt : Int) -> String {
  let test_out = @ui.env("PINSHOT_TEST_REC_OUT")
  if test_out != "" {
    return test_out
  }
  let ext = if fmt == 0 { ".mp4" } else { ".gif" }
  file_in(settings.untracked().save_dir, "PinShot_" + text_of(ps_stamp()) + ext)
}

///|
fn rec_start_now() -> Unit {
  if rec_wid.val == 0 || rec_phase.untracked() != 0 {
    return
  }
  let fmt = rec_fmt.untracked()
  let fps = if fmt == 0 { rec_fps_mp4.untracked() } else { rec_fps_gif.untracked() }
  let cur = if rec_cursor.untracked() { 1 } else { 0 }
  let path = rec_output_path(fmt)
  @signals.start_batch()
  rec_path.set(path)
  rec_ms.set(0)
  rec_frames.set(0)
  rec_bytes.set(0.0)
  rec_err.set("")
  rec_phase.set(1)
  @signals.end_batch()
  if ps_rec_start(cstr(path), fmt, fps, cur) == 0 {
    rec_err.set(tr("启动录屏失败"))
    rec_phase.set(5)
    log("rec: failed to start")
    return
  }
  log("rec: started fmt=\{fmt} fps=\{fps} cursor=\{cur} -> \{path}")
}

///|
fn rec_toggle_pause() -> Unit {
  let ph = rec_phase.untracked()
  if ph == 1 {
    rec_phase.set(2)
    ps_rec_pause(1)
  } else if ph == 2 {
    rec_phase.set(1)
    ps_rec_pause(0)
  }
}

///|
fn rec_finish() -> Unit {
  let ph = rec_phase.untracked()
  if ph != 1 && ph != 2 {
    return
  }
  rec_phase.set(3)
  ps_rec_stop(0)
}

///|
fn rec_cancel() -> Unit {
  let ph = rec_phase.untracked()
  if ph == 1 || ph == 2 {
    rec_phase.set(3)
    ps_rec_stop(1)
  } else if ph != 3 {
    rec_close()
  }
}

///|
fn rec_close() -> Unit {
  if rec_wid.val == 0 {
    return
  }
  ps_rec_end()
  ps_capture_open(0)
  let wid = rec_wid.val
  rec_wid.val = 0
  close_window(wid)
  rec_gone()
}

///|
fn rec_gone() -> Unit {
  if rec_wid.val != 0 {
    rec_wid.val = 0
    ps_rec_end()
    ps_capture_open(0)
  }
  rec_root.val = None
  trim_soon()
}

///|
/// Native recording status callback ({"do":"rec",...}).
fn rec_told(state : String, ms : Int, frames : Int, bytes : Double, codec : String, path : String, err : String) -> Unit {
  if rec_wid.val == 0 {
    return
  }
  match state {
    "recording" => {
      @signals.start_batch()
      if rec_phase.untracked() != 3 {
        rec_phase.set(1)
      }
      rec_ms.set(ms)
      rec_frames.set(frames)
      if codec != "" {
        rec_codec.set(codec)
      }
      @signals.end_batch()
    }
    "paused" => {
      @signals.start_batch()
      if rec_phase.untracked() != 3 {
        rec_phase.set(2)
      }
      rec_ms.set(ms)
      rec_frames.set(frames)
      @signals.end_batch()
    }
    "saving" => rec_phase.set(3)
    "cancelled" => {
      log("rec: cancelled")
      rec_close()
    }
    "done" => {
      shutter()
      ps_capture_open(0)
      @signals.start_batch()
      rec_ms.set(ms)
      rec_frames.set(frames)
      rec_bytes.set(bytes)
      if codec != "" {
        rec_codec.set(codec)
      }
      if path != "" {
        rec_path.set(path)
      }
      rec_phase.set(4)
      rec_done_gen.set(rec_done_gen.untracked() + 1)
      @signals.end_batch()
      log("rec: done \{codec} \{frames}f \{ms}ms \{bytes}B -> \{path}")
    }
    "error" => {
      ps_capture_open(0)
      @signals.start_batch()
      rec_err.set(if err != "" { tr(err) } else { tr("录屏失败") })
      rec_phase.set(5)
      rec_done_gen.set(rec_done_gen.untracked() + 1)
      @signals.end_batch()
      log("rec: error \{err}")
    }
    _ => ()
  }
}

///|
fn rec_fmt_time(ms : Int) -> String {
  let total_s = ms / 1000
  let mins = total_s / 60
  let secs = total_s % 60
  let tenths = (ms % 1000) / 100
  let m_s = if mins < 10 { "0" + mins.to_string() } else { mins.to_string() }
  let s_s = if secs < 10 { "0" + secs.to_string() } else { secs.to_string() }
  "\{m_s}:\{s_s}.\{tenths}"
}

///|
fn rec_fmt_size(bytes : Double) -> String {
  if bytes < 1024.0 {
    "\{bytes.to_int()} B"
  } else if bytes < 1024.0 * 1024.0 {
    let kb = (bytes / 1024.0).round().to_int()
    "\{kb} KB"
  } else {
    let mb10 = (bytes / (1024.0 * 1024.0) * 10.0).round().to_int()
    let whole = mb10 / 10
    let frac = mb10 % 10
    "\{whole}.\{frac} MB"
  }
}

///|
fn rec_short_codec() -> String {
  let c = rec_codec.get()
  if c.has_prefix("HEVC") {
    "H.265"
  } else if c.has_prefix("H.264") {
    "H.264"
  } else if rec_fmt.get() == 1 {
    "GIF"
  } else {
    "MP4"
  }
}

///|
fn rec_keys() -> @view.Keymap {
  let k = fn(code : Int, action : String, mods : Int) -> @view.Binding {
    { keys: [{ code, mods }], action, when: Always }
  }
  @view.Keymap::new([
    k(@ui.key_escape, "cancel", 0),
    k(@ui.key_code_enter, "primary", 0),
    k(@ui.key_space, "space", 0),
  ])
}

///|
fn rec_icon_btn(
  row : @view.View,
  glyph_fn : () -> String,
  label_fn : () -> String,
  lit : () -> Bool,
  press : () -> Unit,
  tint_lit? : Int64 = 0x88C8FFFFL,
  bg_lit? : Int64 = 0x2F9BFF29L,
) -> Unit {
  row.box(fn(b) {
    b
    .width(Is(Some(30.0)))
    .height(Is(Some(30.0)))
    .radius(Is(9.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .cursor(Is(Some(Hand)))
    .says(By(fn() { Some(@view.said(Button, label=label_fn())) }))
    .on_press(press)
    .ground(By(fn() {
      if b.pressed() {
        0xFFFFFF2EL
      } else if lit() {
        bg_lit
      } else if b.pointed() {
        0xFFFFFF17L
      } else {
        0L
      }
    }))
    |> ignore
    b.box(fn(g) {
      g
      .width(Is(Some(16.0)))
      .height(Is(Some(16.0)))
      .picture(By(fn() { Some(glyph(glyph_fn())) }))
      .tint(By(fn() { if lit() { tint_lit } else if b.pointed() { 0xFFFFFFFFL } else { 0xD6DAE0FFL } }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn rec_chip_btn(row : @view.View, text_fn : () -> String, active : () -> Bool, press : () -> Unit) -> Unit {
  row.box(fn(b) {
    b
    .height(Is(Some(28.0)))
    .padding(Is((8.0, 0.0, 8.0, 0.0)))
    .radius(Is(8.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .cursor(Is(Some(Hand)))
    .says(By(fn() { Some(@view.said(Button, label=text_fn())) }))
    .on_press(press)
    .ground(By(fn() {
      if active() {
        0xFFFFFF26L
      } else if b.pointed() {
        0xFFFFFF14L
      } else {
        0L
      }
    }))
    |> ignore
    b.box(fn(t) {
      t
      .words(By(text_fn), look={ ..@view.words_plain, size: 12.0, weight: 600, line: 16.0, wrap: false })
      .ink(By(fn() { if active() { 0xFFFFFFFFL } else { 0x9EA3ABFFL } }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn rec_action_btn(
  row : @view.View,
  dot_color : Int64?,
  glyph_name : String?,
  label_fn : () -> String,
  bg : Int64,
  bg_hover : Int64,
  bg_press : Int64,
  press : () -> Unit,
) -> Unit {
  row.box(fn(b) {
    b
    .row(Is(true))
    .gap(Is(6.0))
    .height(Is(Some(30.0)))
    .padding(Is((12.0, 0.0, 12.0, 0.0)))
    .radius(Is(9.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .cursor(Is(Some(Hand)))
    .says(By(fn() { Some(@view.said(Button, label=label_fn())) }))
    .on_press(press)
    .ground(By(fn() {
      if b.pressed() {
        bg_press
      } else if b.pointed() {
        bg_hover
      } else {
        bg
      }
    }))
    |> ignore
    match dot_color {
      Some(c) =>
        b.box(fn(d) { d.width(Is(Some(8.0))).height(Is(Some(8.0))).radius(Is(4.0)).ground(Is(c)) |> ignore }) |> ignore
      None => ()
    }
    match glyph_name {
      Some(gn) =>
        b.box(fn(g) {
          g.width(Is(Some(14.0))).height(Is(Some(14.0))).picture(Is(Some(glyph(gn)))).tint(Is(0xFFFFFFFFL)) |> ignore
        })
        |> ignore
      None => ()
    }
    b.box(fn(t) {
      t
      .words(By(label_fn), look={ ..@view.words_plain, size: 12.5, weight: 600, line: 16.0, wrap: false })
      .ink(Is(0xFFFFFFFFL))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn rec_window(root : @view.View) -> Unit {
  rec_root.val = Some(root)
  root.tree.hand_over_presses(false)
  root.keymap(Is(rec_keys())) |> ignore
  root.on_action("cancel", fn(_) {
    rec_cancel()
    true
  })
  |> ignore
  root.on_action("primary", fn(_) {
    match rec_phase.untracked() {
      0 => rec_start_now()
      1 | 2 => rec_finish()
      4 | 5 => rec_close()
      _ => ()
    }
    true
  })
  |> ignore
  root.on_action("space", fn(_) {
    match rec_phase.untracked() {
      0 => rec_start_now()
      1 | 2 => rec_toggle_pause()
      _ => ()
    }
    true
  })
  |> ignore

  // Auto-close Done / Error pill after 4.5s unless the user hovers it or opens the folder.
  root.reacts(fn() { rec_done_gen.get() }, fn(gen) {
    if gen == 0 {
      return
    }
    root.at_moment(root.cause_at() + 4500.0, fn() {
      let ph = rec_phase.untracked()
      if rec_wid.val != 0 && (ph == 4 || ph == 5) && gen == rec_done_gen.untracked() {
        if root.pointed() {
          rec_done_gen.set(gen + 1)
        } else {
          rec_close()
        }
      }
    }, later=true)
    |> ignore
  })

  root.box(fn(bar) {
    bar
    .over(Is(true))
    .row(Is(true))
    .gap(Is(4.0))
    .padding(Is((10.0, 0.0, 8.0, 0.0)))
    .ground(Is(0x1E1F23FFL))
    .edge(Is((1.0, 0xFFFFFF18L)))
    .lines_up(Is(Some(Middle)))
    |> ignore

    // Phase 0: Ready
    bar.show(fn() { rec_phase.get() == 0 }, fn(r) {
      r.row(Is(true)).gap(Is(4.0)).grow(Is(1.0)).lines_up(Is(Some(Middle))) |> ignore
      // Draggable status + resolution
      r.box(fn(drag) {
        drag
        .row(Is(true))
        .gap(Is(7.0))
        .grow(Is(1.0))
        .height(Is(Some(32.0)))
        .lines_up(Is(Some(Middle)))
        .presses(Is(true))
        .cursor(Is(Some(Grab)))
        .on_drag(fn(d) {
          if d.kind == Down && rec_wid.val != 0 {
            ps_move_window(rec_wid.val)
          }
        }, whole=true)
        |> ignore
        drag.box(fn(dot) {
          dot.width(Is(Some(8.0))).height(Is(Some(8.0))).radius(Is(4.0)).ground(Is(accent)) |> ignore
        })
        |> ignore
        drag.box(fn(sz) {
          sz
          .words(By(fn() { "\{rec_part.val.w} × \{rec_part.val.h}" }), look={
            ..@view.words_plain,
            size: 12.0,
            weight: 500,
            line: 16.0,
            wrap: false,
          })
          .ink(Is(0xD6DAE0FFL))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // Format toggle (MP4 / GIF)
      r.box(fn(seg) {
        seg
        .row(Is(true))
        .gap(Is(2.0))
        .padding(Is((2.0, 2.0, 2.0, 2.0)))
        .radius(Is(9.0))
        .ground(Is(0xFFFFFF0CL))
        .lines_up(Is(Some(Middle)))
        |> ignore
        rec_chip_btn(seg, fn() { "MP4" }, fn() { rec_fmt.get() == 0 }, fn() { rec_fmt.set(0) })
        rec_chip_btn(seg, fn() { "GIF" }, fn() { rec_fmt.get() == 1 }, fn() { rec_fmt.set(1) })
      })
      |> ignore
      // FPS toggle
      rec_chip_btn(r, fn() { "\{rec_current_fps()}fps" }, fn() { false }, rec_cycle_fps)
      // Cursor toggle
      rec_icon_btn(
        r,
        fn() { "select" },
        fn() { if rec_cursor.get() { tr("录制光标：开") } else { tr("录制光标：关") } },
        fn() { rec_cursor.get() },
        fn() { rec_cursor.set(!rec_cursor.untracked()) },
      )
      bar_rule_node(r)
      rec_icon_btn(r, fn() { "close" }, fn() { tr("取消 Esc") }, fn() { false }, rec_cancel)
      rec_action_btn(
        r,
        Some(0xFFFFFFFFL),
        None,
        fn() { tr("录制") },
        0xE5484DFFL,
        0xF0585DFFL,
        0xCC3A3FFFL,
        rec_start_now,
      )
    })

    // Phase 1 & 2: Recording / Paused
    bar.show(fn() { rec_phase.get() == 1 || rec_phase.get() == 2 }, fn(r) {
      r.row(Is(true)).gap(Is(4.0)).grow(Is(1.0)).lines_up(Is(Some(Middle))) |> ignore
      // Draggable live timer + codec badge
      r.box(fn(drag) {
        drag
        .row(Is(true))
        .gap(Is(8.0))
        .grow(Is(1.0))
        .height(Is(Some(32.0)))
        .lines_up(Is(Some(Middle)))
        .presses(Is(true))
        .cursor(Is(Some(Grab)))
        .on_drag(fn(d) {
          if d.kind == Down && rec_wid.val != 0 {
            ps_move_window(rec_wid.val)
          }
        }, whole=true)
        |> ignore
        drag.box(fn(dot) {
          dot
          .width(Is(Some(8.0)))
          .height(Is(Some(8.0)))
          .radius(Is(4.0))
          .ground(By(fn() { if rec_phase.get() == 2 { 0xF5A524FFL } else { 0xEF4444FFL } }))
          |> ignore
        })
        |> ignore
        drag.box(fn(tm) {
          tm
          .words(By(fn() { rec_fmt_time(rec_ms.get()) }), look={
            ..@view.words_plain,
            size: 13.5,
            weight: 600,
            line: 18.0,
            wrap: false,
          })
          .ink(Is(0xFFFFFFFFL))
          |> ignore
        })
        |> ignore
        drag.box(fn(meta) {
          meta
          .height(Is(Some(20.0)))
          .padding(Is((6.0, 0.0, 6.0, 0.0)))
          .radius(Is(5.0))
          .ground(Is(0xFFFFFF10L))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          |> ignore
          meta.box(fn(w) {
            w
            .words(
              By(fn() {
                if rec_phase.get() == 2 {
                  tr("已暂停")
                } else {
                  "\{rec_short_codec()} · \{rec_current_fps()}fps"
                }
              }),
              look={ ..@view.words_plain, size: 11.0, weight: 500, line: 14.0, wrap: false },
            )
            .ink(By(fn() { if rec_phase.get() == 2 { 0xF5A524FFL } else { 0x9EA3ABFFL } }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      bar_rule_node(r)
      rec_icon_btn(
        r,
        fn() { if rec_phase.get() == 2 { "play" } else { "pause" } },
        fn() { if rec_phase.get() == 2 { tr("继续 Space") } else { tr("暂停 Space") } },
        fn() { rec_phase.get() == 2 },
        rec_toggle_pause,
        tint_lit=0xF5A524FFL,
        bg_lit=0xF5A52426L,
      )
      rec_icon_btn(r, fn() { "close" }, fn() { tr("取消 Esc") }, fn() { false }, rec_cancel)
      rec_action_btn(
        r,
        None,
        Some("stop"),
        fn() { tr("停止") },
        0xE5484DFFL,
        0xF0585DFFL,
        0xCC3A3FFFL,
        rec_finish,
      )
    })

    // Phase 3: Saving
    bar.show(fn() { rec_phase.get() == 3 }, fn(r) {
      r.row(Is(true)).gap(Is(8.0)).grow(Is(1.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      r.box(fn(w) {
        w
        .words(By(fn() { tr("正在保存录屏…") }), look={
          ..@view.words_plain,
          size: 13.0,
          weight: 500,
          line: 18.0,
          wrap: false,
        })
        .ink(Is(0xD6DAE0FFL))
        |> ignore
      })
      |> ignore
    })

    // Phase 4: Done
    bar.show(fn() { rec_phase.get() == 4 }, fn(r) {
      r.row(Is(true)).gap(Is(6.0)).grow(Is(1.0)).lines_up(Is(Some(Middle))) |> ignore
      r.box(fn(drag) {
        drag
        .row(Is(true))
        .gap(Is(7.0))
        .grow(Is(1.0))
        .height(Is(Some(32.0)))
        .lines_up(Is(Some(Middle)))
        .presses(Is(true))
        .cursor(Is(Some(Grab)))
        .on_drag(fn(d) {
          if d.kind == Down && rec_wid.val != 0 {
            ps_move_window(rec_wid.val)
          }
        }, whole=true)
        |> ignore
        drag.box(fn(dot) {
          dot.width(Is(Some(8.0))).height(Is(Some(8.0))).radius(Is(4.0)).ground(Is(0x4CC38AFFL)) |> ignore
        })
        |> ignore
        drag.box(fn(w) {
          w
          .words(By(fn() { tr("已保存并复制") + " · " + rec_fmt_size(rec_bytes.get()) }), look={
            ..@view.words_plain,
            size: 12.5,
            weight: 500,
            line: 16.0,
            wrap: false,
          })
          .ink(Is(0xECEEF2FFL))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      rec_action_btn(
        r,
        None,
        None,
        fn() { tr("打开位置") },
        0xFFFFFF1CL,
        0xFFFFFF29L,
        0xFFFFFF36L,
        fn() {
          let p = rec_path.untracked()
          if p != "" {
            ps_reveal(cstr(p))
          }
          rec_close()
        },
      )
      rec_icon_btn(r, fn() { "close" }, fn() { tr("关闭") }, fn() { false }, rec_close)
    })

    // Phase 5: Error
    bar.show(fn() { rec_phase.get() == 5 }, fn(r) {
      r.row(Is(true)).gap(Is(6.0)).grow(Is(1.0)).lines_up(Is(Some(Middle))) |> ignore
      r.box(fn(dot) {
        dot.width(Is(Some(8.0))).height(Is(Some(8.0))).radius(Is(4.0)).ground(Is(0xF5A524FFL)) |> ignore
      })
      |> ignore
      r.box(fn(w) {
        w
        .grow(Is(1.0))
        .words(By(fn() { rec_err.get() }), look={
          ..@view.words_plain,
          size: 12.5,
          weight: 500,
          line: 16.0,
          wrap: false,
        })
        .ink(Is(0xF5A524FFL))
        |> ignore
      })
      |> ignore
      rec_icon_btn(r, fn() { "close" }, fn() { tr("关闭") }, fn() { false }, rec_close)
    })
  })
  |> ignore
}
