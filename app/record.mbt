// Lightweight area screen recorder & post-recording exporter (Windows):
// - Captures a selected region into a temporary high-quality MP4 via WGC + optimal GPU hardware cascade
//   (HEVC hvc1 -> H.264 HW -> H.264 SW) with optional WASAPI system audio (AAC), cursor capture, mouse-click ripples +
//   keycap overlay, and live transparent GDI+ annotations (rect, arrow, pen, number, undo, clear).
// - Adaptive content-fitted floating control bar (no hardcoded width, no dead gaps in EN or ZH).
// - After stopping, opens a compact post-recording encoding panel with explicit controls for:
//     * Format / Codec: MP4 (H.265), MP4 (H.264), GIF
//     * Video Quality: Original (zero re-encode when codec/size match), High, Balanced, Compact (or GIF 10/15/20 fps)
//     * Resolution: Original, 1080p, 720p (+ 480p for GIF)
// - Saves into the screenshots folder (or Save As) and copies the exported file (CF_HDROP) to clipboard.

///|
extern "C" fn ps_rec_prepare(x : Int, y : Int, w : Int, h : Int) -> Int = "ps_rec_prepare"

///|
extern "C" fn ps_rec_rect() -> Bytes = "ps_rec_rect"

///|
extern "C" fn ps_rec_start(fps : Int, cursor : Int, audio : Int) -> Int = "ps_rec_start"

///|
extern "C" fn ps_rec_pause(on : Int) -> Unit = "ps_rec_pause"

///|
extern "C" fn ps_rec_stop(cancel : Int) -> Unit = "ps_rec_stop"

///|
#borrow(dest_path)
extern "C" fn ps_rec_export(dest_path : Bytes, fmt : Int, quality : Int, max_side : Int, gif_fps : Int) -> Int = "ps_rec_export"

///|
extern "C" fn ps_rec_end() -> Unit = "ps_rec_end"

///|
extern "C" fn ps_rec_exclude(wid : Int) -> Unit = "ps_rec_exclude"

///|
extern "C" fn ps_rec_draw_tool(tool : Int) -> Unit = "ps_rec_draw_tool"

///|
extern "C" fn ps_rec_draw_color(rgb : Int) -> Unit = "ps_rec_draw_color"

///|
extern "C" fn ps_rec_draw_undo() -> Unit = "ps_rec_draw_undo"

///|
extern "C" fn ps_rec_draw_clear() -> Unit = "ps_rec_draw_clear"

///|
extern "C" fn ps_rec_input_show(on : Int) -> Unit = "ps_rec_input_show"

///|
fn rec_here() -> Bool {
  @hostapi.platform() == 3
}

///|
let rec_wid : Ref[Int] = Ref(0)

///|
let rec_root : Ref[@view.View?] = Ref(None)

///|
let rec_content : Ref[@view.View?] = Ref(None)

///|
let rec_placed_size : Ref[(Int, Int)] = Ref((0, 0))

///|
let rec_part : Ref[Rect] = Ref({ x: 0, y: 0, w: 0, h: 0 })

///|
let rec_mon : Ref[Rect] = Ref({ x: 0, y: 0, w: 0, h: 0 })

///|
let rec_scale : Ref[Double] = Ref(1.0)

///|
/// Phase: 0 Ready, 1 Recording, 2 Paused, 3 Finalizing master, 4 Export picker, 5 Exporting, 6 Exported, 7 Error.
let rec_phase : @signals.Signal[Int] = @signals.signal(0)

///|
/// Recording options (remembered for the session).
let rec_fps : @signals.Signal[Int] = @signals.signal(30)

///|
let rec_cursor : @signals.Signal[Bool] = @signals.signal(true)

///|
let rec_audio : @signals.Signal[Bool] = @signals.signal(false)

///|
let rec_input : @signals.Signal[Bool] = @signals.signal(false)

///|
/// Live annotation state: 0 passthrough, 1 rect, 2 arrow, 3 pen, 4 number.
let rec_draw : @signals.Signal[Int] = @signals.signal(0)

///|
let rec_marks_n : @signals.Signal[Int] = @signals.signal(0)

///|
let rec_draw_colors : Array[(Int, Int64)] = [
  (0xD84A2F, 0xD84A2FFFL),
  (0xF5A524, 0xF5A524FFL),
  (0x2F9BFF, 0x2F9BFFFFL),
  (0x4CC38A, 0x4CC38AFFL),
]

///|
let rec_color_i : @signals.Signal[Int] = @signals.signal(0)

///|
/// Export options (remembered across recordings):
/// fmt: 0 = MP4 H.265, 1 = MP4 H.264, 2 = GIF
let rec_exp_fmt : @signals.Signal[Int] = @signals.signal(0)

///|
/// quality: 0 = Original, 1 = High, 2 = Balanced (default), 3 = Compact
let rec_exp_qual : @signals.Signal[Int] = @signals.signal(2)

///|
/// max_side: 0 = Original, 1920 = 1080p, 1280 = 720p, 854 = 480p (GIF)
let rec_exp_scale : @signals.Signal[Int] = @signals.signal(0)

///|
/// GIF fps: 10, 15 (default), 20
let rec_exp_gif_fps : @signals.Signal[Int] = @signals.signal(15)

///|
/// Live & master stats from native side.
let rec_ms : @signals.Signal[Int] = @signals.signal(0)

///|
let rec_frames : @signals.Signal[Int] = @signals.signal(0)

///|
let rec_master_bytes : @signals.Signal[Double] = @signals.signal(0.0)

///|
let rec_master_audio : @signals.Signal[Bool] = @signals.signal(false)

///|
let rec_exp_bytes : @signals.Signal[Double] = @signals.signal(0.0)

///|
let rec_exp_pct : @signals.Signal[Int] = @signals.signal(0)

///|
let rec_codec : @signals.Signal[String] = @signals.signal("")

///|
let rec_path : @signals.Signal[String] = @signals.signal("")

///|
let rec_err : @signals.Signal[String] = @signals.signal("")

///|
fn rec_pick_draw(t : Int) -> Unit {
  let next = if rec_draw.untracked() == t { 0 } else { t }
  rec_draw.set(next)
  ps_rec_draw_tool(next)
}

///|
fn rec_cycle_color() -> Unit {
  let next = (rec_color_i.untracked() + 1) % rec_draw_colors.length()
  rec_color_i.set(next)
  ps_rec_draw_color(rec_draw_colors[next].0)
}

///|
fn rec_out_dims(max_side : Int) -> (Int, Int) {
  let sw = rec_part.val.w
  let sh = rec_part.val.h
  if max_side <= 0 || (sw <= max_side && sh <= max_side) {
    (sw, sh)
  } else {
    let long = if sw > sh { sw } else { sh }
    let k = max_side.to_double() / long.to_double()
    let ow = clampi(((sw.to_double() * k + 0.5).to_int()) & -2, 16, sw)
    let oh = clampi(((sh.to_double() * k + 0.5).to_int()) & -2, 16, sh)
    (ow, oh)
  }
}

///|
fn rec_is_direct_copy() -> Bool {
  let fmt = rec_exp_fmt.get()
  let q = rec_exp_qual.get()
  let ms = rec_exp_scale.get()
  let (ow, oh) = rec_out_dims(ms)
  let same_dim = ow == rec_part.val.w && oh == rec_part.val.h
  let master_hevc = rec_codec.get().has_prefix("HEVC")
  (fmt == 0 || fmt == 1) && q == 0 && same_dim && ((fmt == 0) == master_hevc)
}

///|
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
  rec_placed_size.val = (0, 0)
  @signals.start_batch()
  rec_phase.set(0)
  rec_draw.set(0)
  rec_marks_n.set(0)
  rec_ms.set(0)
  rec_frames.set(0)
  rec_master_bytes.set(0.0)
  rec_master_audio.set(false)
  rec_exp_bytes.set(0.0)
  rec_exp_pct.set(0)
  rec_codec.set("")
  rec_path.set("")
  rec_err.set("")
  @signals.end_batch()
  ps_rec_draw_color(rec_draw_colors[rec_color_i.untracked()].0)
  ps_rec_input_show(if rec_input.untracked() { 1 } else { 0 })
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
  rec_place_initial(560.0, 46.0, true)
  rec_schedule_fit(true)
  log("rec: ready \{part.w}x\{part.h} at \{part.x},\{part.y}")
}

///|
/// Initial placement under (or over, or centered on) the selected region.
fn rec_place_initial(pt_w : Double, pt_h : Double, focus : Bool) -> Unit {
  let m = rec_mon.val
  let k = rec_scale.val
  let p = rec_part.val
  let w = (pt_w * k).round().to_int()
  let h = (pt_h * k).round().to_int()
  let gap = (10.0 * k).round().to_int()
  let x = clampi(p.x + (p.w - w) / 2, m.x + gap, m.right() - gap - w)
  let y = if p.bottom() + gap + h <= m.bottom() - gap {
    p.bottom() + gap
  } else if p.y - gap - h >= m.y + gap {
    p.y - gap - h
  } else {
    clampi(p.y + (p.h - h) / 2, m.y + gap, m.bottom() - gap - h)
  }
  rec_placed_size.val = (w, h)
  ps_place(rec_wid.val, x, y, w, h, 1, if focus { 1 } else { 0 })
}

///|
/// Measure the inner content box and resize the window snugly around its current horizontal center.
fn rec_fit_window(focus : Bool) -> Unit {
  if rec_wid.val == 0 {
    return
  }
  guard rec_content.val is Some(content) else { return }
  let (cw, ch) = content.laid_size()
  if cw < 20.0 || ch < 20.0 {
    return
  }
  let m = rec_mon.val
  let k = rec_scale.val
  // +2 pt accounts for the 1 pt border on each side of `page`
  let w = ((cw + 2.0) * k).ceil().to_int()
  let h = ((ch + 2.0) * k).ceil().to_int()
  let (pw, ph) = rec_placed_size.val
  if (w - pw).abs() <= 1 && (h - ph).abs() <= 1 && !focus {
    return
  }
  let gap = (10.0 * k).round().to_int()
  let r = numbers_of(text_of(ps_window_rect(rec_wid.val)))
  let (cx, top) = if r.length() >= 4 && r[2] > 0.0 && r[3] > 0.0 {
    ((r[0] + r[2] / 2.0).round().to_int(), r[1].round().to_int())
  } else {
    let p = rec_part.val
    (p.x + p.w / 2, p.bottom() + gap)
  }
  let x = clampi(cx - w / 2, m.x + gap, m.right() - gap - w)
  let y = clampi(top, m.y + gap, m.bottom() - gap - h)
  rec_placed_size.val = (w, h)
  ps_place(rec_wid.val, x, y, w, h, 1, if focus { 1 } else { 0 })
}

///|
fn rec_schedule_fit(focus : Bool) -> Unit {
  match rec_root.val {
    Some(root) =>
      root.at_moment(root.cause_at() + 1.0, fn() { rec_fit_window(focus) }, later=true) |> ignore
    None => ()
  }
}

///|
fn rec_start_now() -> Unit {
  if rec_wid.val == 0 || rec_phase.untracked() != 0 {
    return
  }
  let fps = rec_fps.untracked()
  let cur = if rec_cursor.untracked() { 1 } else { 0 }
  let aud = if rec_audio.untracked() { 1 } else { 0 }
  @signals.start_batch()
  rec_ms.set(0)
  rec_frames.set(0)
  rec_err.set("")
  rec_phase.set(1)
  @signals.end_batch()
  ps_rec_input_show(if rec_input.untracked() { 1 } else { 0 })
  if ps_rec_start(fps, cur, aud) == 0 {
    rec_err.set(tr("启动录屏失败"))
    rec_phase.set(7)
    log("rec: failed to start")
    return
  }
  log("rec: started fps=\{fps} cursor=\{cur} audio=\{aud}")
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
fn rec_finish_capture() -> Unit {
  let ph = rec_phase.untracked()
  if ph != 1 && ph != 2 {
    return
  }
  rec_draw.set(0)
  rec_phase.set(3)
  ps_rec_stop(0)
}

///|
fn rec_export_dest(ask_dialog : Bool) -> String {
  let test_out = @ui.env("PINSHOT_TEST_REC_OUT")
  if test_out != "" && !ask_dialog {
    return test_out
  }
  let ext = if rec_exp_fmt.untracked() == 2 { ".gif" } else { ".mp4" }
  let name = "PinShot_" + text_of(ps_stamp()) + ext
  let dir = settings.untracked().save_dir
  if ask_dialog {
    text_of(ps_save_dialog(rec_wid.val, cstr(dir), cstr(name)))
  } else {
    file_in(dir, name)
  }
}

///|
fn rec_run_export(ask_dialog : Bool) -> Unit {
  let ph = rec_phase.untracked()
  if rec_wid.val == 0 || (ph != 4 && ph != 6 && ph != 7) {
    return
  }
  let dest = rec_export_dest(ask_dialog)
  if dest == "" {
    return
  }
  let fmt = rec_exp_fmt.untracked()
  let qual = rec_exp_qual.untracked()
  let max_side = rec_exp_scale.untracked()
  let gif_fps = rec_exp_gif_fps.untracked()
  @signals.start_batch()
  rec_path.set(dest)
  rec_exp_pct.set(0)
  rec_err.set("")
  rec_phase.set(5)
  @signals.end_batch()
  if ps_rec_export(cstr(dest), fmt, qual, max_side, gif_fps) == 0 {
    rec_err.set(tr("启动导出失败"))
    rec_phase.set(7)
  } else {
    log("rec: export fmt=\{fmt} q=\{qual} max=\{max_side} gfps=\{gif_fps} -> \{dest}")
  }
}

///|
fn rec_cancel() -> Unit {
  let ph = rec_phase.untracked()
  if ph == 1 || ph == 2 {
    rec_draw.set(0)
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
  rec_content.val = None
  rec_placed_size.val = (0, 0)
  trim_soon()
}

///|
fn rec_draw_told(tool : Int, count : Int) -> Unit {
  if rec_wid.val == 0 {
    return
  }
  @signals.start_batch()
  rec_draw.set(tool)
  rec_marks_n.set(count)
  @signals.end_batch()
}

///|
fn rec_told(
  state : String,
  ms : Int,
  frames : Int,
  bytes : Double,
  orig : Double,
  pct : Int,
  audio : Int,
  codec : String,
  path : String,
  err : String,
) -> Unit {
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
      rec_master_audio.set(audio != 0)
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
    "recorded" => {
      ps_capture_open(0)
      @signals.start_batch()
      rec_ms.set(ms)
      rec_frames.set(frames)
      rec_master_bytes.set(bytes)
      rec_master_audio.set(audio != 0)
      if codec != "" {
        rec_codec.set(codec)
      }
      rec_phase.set(4)
      @signals.end_batch()
      rec_schedule_fit(true)
      log("rec: master ready \{codec} audio=\{audio} \{frames}f \{ms}ms \{bytes}B")
    }
    "exporting" => {
      @signals.start_batch()
      rec_phase.set(5)
      rec_exp_pct.set(pct)
      @signals.end_batch()
    }
    "exported" => {
      shutter()
      @signals.start_batch()
      rec_exp_bytes.set(bytes)
      if orig > 0.0 {
        rec_master_bytes.set(orig)
      }
      rec_exp_pct.set(100)
      if path != "" {
        rec_path.set(path)
      }
      rec_phase.set(6)
      @signals.end_batch()
      rec_schedule_fit(false)
      log("rec: exported \{codec} \{bytes}B (orig \{orig}B) -> \{path}")
    }
    "export-error" => {
      @signals.start_batch()
      rec_err.set(if err != "" { tr(err) } else { tr("导出失败") })
      rec_phase.set(7)
      @signals.end_batch()
      rec_schedule_fit(false)
      log("rec: export-error \{err}")
    }
    "error" => {
      ps_capture_open(0)
      @signals.start_batch()
      rec_err.set(if err != "" { tr(err) } else { tr("录屏失败") })
      rec_phase.set(7)
      @signals.end_batch()
      rec_schedule_fit(false)
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
  } else {
    "MP4"
  }
}

///|
fn rec_saved_pct_tag() -> String {
  let orig = rec_master_bytes.get()
  let out = rec_exp_bytes.get()
  if orig > 0.0 && out > 0.0 && out < orig * 0.96 {
    let saved = ((orig - out) / orig * 100.0).round().to_int()
    if saved > 0 {
      if english.get() {
        " (-\{saved}%)"
      } else {
        "（-\{saved}%）"
      }
    } else {
      ""
    }
  } else {
    ""
  }
}

///|
fn rec_spec_summary() -> String {
  let fmt = rec_exp_fmt.get()
  let (ow, oh) = rec_out_dims(rec_exp_scale.get())
  if fmt == 2 {
    "\{ow}×\{oh} · \{rec_exp_gif_fps.get()}fps · GIF"
  } else if rec_is_direct_copy() {
    let tag = if fmt == 0 { "H.265" } else { "H.264" }
    tr("零重编码直出") + " · \{tag} · " + rec_fmt_size(rec_master_bytes.get())
  } else {
    let tag = if fmt == 0 { "H.265" } else { "H.264" }
    let q_lbl = match rec_exp_qual.get() {
      0 => tr("原画")
      1 => tr("高画质")
      2 => tr("标准")
      _ => tr("小体积")
    }
    "\{ow}×\{oh} · \{tag} · \{q_lbl}"
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
  dim? : () -> Bool = fn() { false },
  tint_lit? : Int64 = 0x88C8FFFFL,
  bg_lit? : Int64 = 0x2F9BFF29L,
) -> Unit {
  row.box(fn(b) {
    b
    .width(Is(Some(28.0)))
    .height(Is(Some(28.0)))
    .shrink(Is(0.0))
    .radius(Is(8.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .cursor(By(fn() { if dim() { None } else { Some(Hand) } }))
    .says(By(fn() { Some(@view.said(Button, label=label_fn())) }))
    .on_press(fn() { if !dim() { press() } })
    .ground(By(fn() {
      if dim() {
        0L
      } else if b.pressed() {
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
      .width(Is(Some(15.0)))
      .height(Is(Some(15.0)))
      .picture(By(fn() { Some(glyph(glyph_fn())) }))
      .tint(By(fn() {
        if dim() {
          0xFFFFFF40L
        } else if lit() {
          tint_lit
        } else if b.pointed() {
          0xFFFFFFFFL
        } else {
          0xD6DAE0FFL
        }
      }))
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
  dim? : () -> Bool = fn() { false },
) -> Unit {
  row.box(fn(b) {
    b
    .row(Is(true))
    .gap(Is(6.0))
    .height(Is(Some(30.0)))
    .shrink(Is(0.0))
    .padding(Is((11.0, 0.0, 12.0, 0.0)))
    .radius(Is(9.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .cursor(By(fn() { if dim() { None } else { Some(Hand) } }))
    .says(By(fn() { Some(@view.said(Button, label=label_fn())) }))
    .on_press(fn() { if !dim() { press() } })
    .ground(By(fn() {
      if dim() {
        0xFFFFFF14L
      } else if b.pressed() {
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
        b.box(fn(d) {
          d.width(Is(Some(8.0))).height(Is(Some(8.0))).shrink(Is(0.0)).radius(Is(4.0)).ground(Is(c)) |> ignore
        })
        |> ignore
      None => ()
    }
    match glyph_name {
      Some(gn) =>
        b.box(fn(g) {
          g.width(Is(Some(14.0))).height(Is(Some(14.0))).shrink(Is(0.0)).picture(Is(Some(glyph(gn)))).tint(Is(0xFFFFFFFFL))
          |> ignore
        })
        |> ignore
      None => ()
    }
    b.box(fn(t) {
      t
      .shrink(Is(0.0))
      .words(By(label_fn), look={ ..@view.words_plain, size: 12.5, weight: 600, line: 16.0, wrap: false })
      .ink(By(fn() { if dim() { 0xFFFFFF59L } else { 0xFFFFFFFFL } }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn rec_seg_pill(
  row : @view.View,
  label_fn : () -> String,
  active : () -> Bool,
  press : () -> Unit,
  dim? : () -> Bool = fn() { false },
) -> Unit {
  row.box(fn(b) {
    b
    .height(Is(Some(28.0)))
    .shrink(Is(0.0))
    .padding(Is((10.0, 0.0, 10.0, 0.0)))
    .radius(Is(7.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .cursor(By(fn() { if dim() { None } else { Some(Hand) } }))
    .says(By(fn() { Some(@view.said(Button, label=label_fn())) }))
    .on_press(fn() {
      if !dim() && rec_phase.untracked() != 5 {
        if rec_phase.untracked() == 6 {
          rec_phase.set(4)
        }
        press()
      }
    })
    .ground(By(fn() {
      if dim() {
        0xFFFFFF05L
      } else if active() {
        0x2F9BFF28L
      } else if b.pointed() {
        0xFFFFFF16L
      } else {
        0xFFFFFF0AL
      }
    }))
    .edge(By(fn() {
      if active() && !dim() {
        (1.2, 0x2F9BFFCCL)
      } else {
        (1.0, 0xFFFFFF14L)
      }
    }))
    |> ignore
    b.box(fn(t) {
      t
      .shrink(Is(0.0))
      .words(By(label_fn), look={ ..@view.words_plain, size: 12.0, weight: 500, line: 16.0, wrap: false })
      .ink(By(fn() {
        if dim() {
          0xFFFFFF3AL
        } else if active() {
          0xFFFFFFFFL
        } else {
          0xD0D4DCFFL
        }
      }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn rec_form_row(parent : @view.View, label_key : String, build : (@view.View) -> Unit) -> Unit {
  parent.box(fn(r) {
    r.row(Is(true)).gap(Is(8.0)).height(Is(Some(28.0))).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore
    r.box(fn(lbl) {
      lbl.min_width(Is(Some(56.0))).shrink(Is(0.0)).lines_up(Is(Some(Start))) |> ignore
      lbl.box(fn(t) {
        t
        .shrink(Is(0.0))
        .words(By(fn() { tr(label_key) }), look={ ..@view.words_plain, size: 12.0, weight: 500, line: 16.0, wrap: false })
        .ink(Is(0x9EA3ABFFL))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    r.box(fn(opts) {
      opts.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore
      build(opts)
    })
    |> ignore
  })
  |> ignore
}

///|
fn rec_hrule(parent : @view.View) -> Unit {
  parent.box(fn(ln) { ln.height(Is(Some(1.0))).ground(Is(0xFFFFFF12L)) |> ignore }) |> ignore
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
      1 | 2 => rec_finish_capture()
      4 | 6 => rec_run_export(false)
      7 => rec_close()
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

  // Re-measure and adapt window dimensions cleanly whenever UI structure/labels change (never on timer ticks).
  root.reacts(fn() {
    (
      rec_phase.get(),
      rec_codec.get(),
      rec_fps.get(),
      rec_exp_fmt.get(),
      rec_exp_qual.get(),
      rec_exp_scale.get(),
      rec_exp_gif_fps.get(),
      rec_master_audio.get(),
      english.get(),
    )
  }, fn(_) { rec_schedule_fit(false) })

  root.box(fn(page) {
    page
    .over(Is(true))
    .ground(Is(0x1E1F23FFL))
    .edge(Is((1.0, 0xFFFFFF18L)))
    .lines_up(Is(Some(Start)))
    |> ignore

    // Content container whose intrinsic laid_size() drives adaptive window sizing
    page.box(fn(content) {
      rec_content.val = Some(content)
      content.shrink(Is(0.0)).lines_up(Is(Some(Start))) |> ignore

      // ---- Phases 0..3: Compact content-fitted single-row live control bar ----
      content.show(fn() { rec_phase.get() <= 3 }, fn(bar) {
        bar
        .row(Is(true))
        .gap(Is(3.0))
        .height(Is(Some(44.0)))
        .shrink(Is(0.0))
        .padding(Is((10.0, 0.0, 8.0, 0.0)))
        .lines_up(Is(Some(Middle)))
        |> ignore

        // Phase 3: Finalizing master
        bar.show(fn() { rec_phase.get() == 3 }, fn(r) {
          r.row(Is(true)).min_width(Is(Some(200.0))).shrink(Is(0.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle))
          |> ignore
          r.box(fn(w) {
            w
            .shrink(Is(0.0))
            .words(By(fn() { tr("正在收尾录屏…") }), look={
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
        }, at_once=true)

        // Phases 0, 1, 2: Ready / Recording / Paused
        bar.show(fn() { rec_phase.get() <= 2 }, fn(r) {
          r.row(Is(true)).gap(Is(3.0)).shrink(Is(0.0)).lines_up(Is(Some(Middle))) |> ignore

          // Draggable left status + tabular timer
          r.box(fn(drag) {
            drag
            .row(Is(true))
            .gap(Is(7.0))
            .height(Is(Some(32.0)))
            .shrink(Is(0.0))
            .padding(Is((0.0, 0.0, 4.0, 0.0)))
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
              .shrink(Is(0.0))
              .radius(Is(4.0))
              .ground(By(fn() {
                match rec_phase.get() {
                  1 => 0xEF4444FFL
                  2 => 0xF5A524FFL
                  _ => accent
                }
              }))
              |> ignore
            })
            |> ignore
            // Fixed min-width + tabular theme guarantees 0px horizontal jitter on ticks
            drag.box(fn(tm_box) {
              tm_box.min_width(Is(Some(54.0))).shrink(Is(0.0)).lines_up(Is(Some(Start))) |> ignore
              tm_box.box(fn(tm) {
                tm
                .shrink(Is(0.0))
                .words(By(fn() { rec_fmt_time(rec_ms.get()) }), look={
                  ..@view.words_plain,
                  size: 13.0,
                  weight: 600,
                  line: 18.0,
                  wrap: false,
                })
                .ink(By(fn() { if rec_phase.get() == 0 { 0xB8BDC6FFL } else { 0xFFFFFFFFL } }))
                |> ignore
              })
              |> ignore
            })
            |> ignore
          })
          |> ignore

          // FPS / codec pill (clickable in Ready to switch 30 / 60fps)
          r.box(fn(fps_b) {
            fps_b
            .height(Is(Some(24.0)))
            .shrink(Is(0.0))
            .padding(Is((7.0, 0.0, 7.0, 0.0)))
            .radius(Is(6.0))
            .lines_up(Is(Some(Middle)))
            .lies_along(Is(Middle))
            .presses(Is(true))
            .cursor(By(fn() { if rec_phase.get() == 0 { Some(Hand) } else { None } }))
            .says(By(fn() { Some(@view.said(Button, label="\{rec_fps.get()}fps")) }))
            .on_press(fn() {
              if rec_phase.untracked() == 0 {
                rec_fps.set(if rec_fps.untracked() == 30 { 60 } else { 30 })
              }
            })
            .ground(By(fn() {
              if rec_phase.get() == 0 && fps_b.pointed() {
                0xFFFFFF1CL
              } else {
                0xFFFFFF10L
              }
            }))
            |> ignore
            fps_b.box(fn(w) {
              w
              .shrink(Is(0.0))
              .words(
                By(fn() {
                  if rec_phase.get() == 2 {
                    tr("已暂停")
                  } else if rec_phase.get() == 1 {
                    "\{rec_short_codec()}·\{rec_fps.get()}"
                  } else {
                    "\{rec_fps.get()}fps"
                  }
                }),
                look={ ..@view.words_plain, size: 11.0, weight: 500, line: 14.0, wrap: false },
              )
              .ink(By(fn() { if rec_phase.get() == 2 { 0xF5A524FFL } else { 0xB8BDC6FFL } }))
              |> ignore
            })
            |> ignore
          })
          |> ignore

          // Pre-recording capture switches (System audio, Cursor, Click & keycap overlay): hidden once recording starts
          r.show(fn() { rec_phase.get() == 0 }, fn(opts) {
            opts.row(Is(true)).gap(Is(3.0)).shrink(Is(0.0)).lines_up(Is(Some(Middle))) |> ignore
            rec_icon_btn(
              opts,
              fn() { if rec_audio.get() { "speaker" } else { "speaker-off" } },
              fn() { if rec_audio.get() { tr("系统声音：开") } else { tr("系统声音：关") } },
              fn() { rec_audio.get() },
              fn() { rec_audio.set(!rec_audio.untracked()) },
            )
            rec_icon_btn(
              opts,
              fn() { "select" },
              fn() { if rec_cursor.get() { tr("录制光标：开") } else { tr("录制光标：关") } },
              fn() { rec_cursor.get() },
              fn() { rec_cursor.set(!rec_cursor.untracked()) },
            )
            rec_icon_btn(
              opts,
              fn() { "keycap" },
              fn() { if rec_input.get() { tr("按键与点击显示：开") } else { tr("按键与点击显示：关") } },
              fn() { rec_input.get() },
              fn() {
                let next = !rec_input.untracked()
                rec_input.set(next)
                ps_rec_input_show(if next { 1 } else { 0 })
              },
            )
          }, at_once=true)

          bar_rule_node(r)

          // Live annotation tools (rect, arrow, pen, number, color swatch, undo, clear)
          rec_icon_btn(r, fn() { "box" }, fn() { tr("矩形") }, fn() { rec_draw.get() == 1 }, fn() { rec_pick_draw(1) })
          rec_icon_btn(r, fn() { "arrow" }, fn() { tr("箭头") }, fn() { rec_draw.get() == 2 }, fn() { rec_pick_draw(2) })
          rec_icon_btn(r, fn() { "pen" }, fn() { tr("画笔") }, fn() { rec_draw.get() == 3 }, fn() { rec_pick_draw(3) })
          rec_icon_btn(r, fn() { "number" }, fn() { tr("序号") }, fn() { rec_draw.get() == 4 }, fn() { rec_pick_draw(4) })
          // Color swatch dot
          r.box(fn(cb) {
            cb
            .width(Is(Some(24.0)))
            .height(Is(Some(28.0)))
            .shrink(Is(0.0))
            .radius(Is(8.0))
            .lines_up(Is(Some(Middle)))
            .lies_along(Is(Middle))
            .presses(Is(true))
            .cursor(Is(Some(Hand)))
            .says(By(fn() { Some(@view.said(Button, label=tr("切换标注颜色"))) }))
            .on_press(rec_cycle_color)
            .ground(By(fn() { if cb.pointed() { 0xFFFFFF17L } else { 0L } }))
            |> ignore
            cb.box(fn(sw) {
              sw
              .width(Is(Some(12.0)))
              .height(Is(Some(12.0)))
              .radius(Is(6.0))
              .ground(By(fn() { rec_draw_colors[rec_color_i.get()].1 }))
              .edge(Is((1.5, 0xFFFFFF66L)))
              |> ignore
            })
            |> ignore
          })
          |> ignore
          rec_icon_btn(
            r,
            fn() { "undo" },
            fn() { tr("撤销标注") },
            fn() { false },
            ps_rec_draw_undo,
            dim=fn() { rec_marks_n.get() == 0 },
          )
          rec_icon_btn(
            r,
            fn() { "eraser" },
            fn() { tr("清空标注") },
            fn() { false },
            ps_rec_draw_clear,
            dim=fn() { rec_marks_n.get() == 0 },
          )

          bar_rule_node(r)

          // Pause / Resume (recording or paused)
          r.show(fn() { rec_phase.get() == 1 || rec_phase.get() == 2 }, fn(pb) {
            pb.shrink(Is(0.0)) |> ignore
            rec_icon_btn(
              pb,
              fn() { if rec_phase.get() == 2 { "play" } else { "pause" } },
              fn() { if rec_phase.get() == 2 { tr("继续 Space") } else { tr("暂停 Space") } },
              fn() { rec_phase.get() == 2 },
              rec_toggle_pause,
              tint_lit=0xF5A524FFL,
              bg_lit=0xF5A52426L,
            )
          }, at_once=true)
          rec_icon_btn(r, fn() { "close" }, fn() { tr("取消 Esc") }, fn() { false }, rec_cancel)
          // Start (Ready) or Stop (Recording / Paused)
          r.show(fn() { rec_phase.get() == 0 }, fn(sb) {
            sb.shrink(Is(0.0)) |> ignore
            rec_action_btn(
              sb,
              Some(0xFFFFFFFFL),
              None,
              fn() { tr("录制") },
              0xE5484DFFL,
              0xF0585DFFL,
              0xCC3A3FFFL,
              rec_start_now,
            )
          }, at_once=true)
          r.show(fn() { rec_phase.get() == 1 || rec_phase.get() == 2 }, fn(sb) {
            sb.shrink(Is(0.0)) |> ignore
            rec_action_btn(
              sb,
              None,
              Some("stop"),
              fn() { tr("停止") },
              0xE5484DFFL,
              0xF0585DFFL,
              0xCC3A3FFFL,
              rec_finish_capture,
            )
          }, at_once=true)
        }, at_once=true)
      }, at_once=true)

      // ---- Phases 4..7: Post-recording encoding & quality panel (content-fitted) ----
      content.show(fn() { rec_phase.get() >= 4 }, fn(exp) {
        exp
        .min_width(Is(Some(470.0)))
        .shrink(Is(0.0))
        .padding(Is((14.0, 12.0, 14.0, 12.0)))
        .gap(Is(10.0))
        |> ignore

        // 1. Draggable header: recorded summary + audio badge + close
        exp.box(fn(hd) {
          hd.row(Is(true)).gap(Is(10.0)).height(Is(Some(26.0))).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore
          hd.box(fn(drag) {
            drag
            .row(Is(true))
            .gap(Is(8.0))
            .grow(Is(1.0))
            .height(Is(Some(26.0)))
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
              .shrink(Is(0.0))
              .radius(Is(4.0))
              .ground(By(fn() { if rec_phase.get() == 7 { 0xF5A524FFL } else { 0x4CC38AFFL } }))
              |> ignore
            })
            |> ignore
            drag.box(fn(info) {
              info
              .shrink(Is(0.0))
              .words(
                By(fn() {
                  let dur = rec_fmt_time(rec_ms.get())
                  let sz = rec_fmt_size(rec_master_bytes.get())
                  tr("录制完成") + " · \{dur} · \{rec_part.val.w}×\{rec_part.val.h} · \{sz}"
                }),
                look={ ..@view.words_plain, size: 12.5, weight: 600, line: 16.0, wrap: false },
              )
              .ink(Is(0xECEEF2FFL))
              |> ignore
            })
            |> ignore
            drag.show(fn() { rec_master_audio.get() }, fn(ab) {
              ab
              .height(Is(Some(18.0)))
              .shrink(Is(0.0))
              .padding(Is((5.0, 0.0, 5.0, 0.0)))
              .radius(Is(5.0))
              .ground(Is(0x2F9BFF24L))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              |> ignore
              ab.box(fn(t) {
                t
                .shrink(Is(0.0))
                .words(By(fn() { tr("含声音") }), look={
                  ..@view.words_plain,
                  size: 10.5,
                  weight: 500,
                  line: 14.0,
                  wrap: false,
                })
                .ink(Is(0x88C8FFFFL))
                |> ignore
              })
              |> ignore
            }, at_once=true)
          })
          |> ignore
          rec_icon_btn(hd, fn() { "close" }, fn() { tr("关闭 Esc") }, fn() { false }, rec_close)
        })
        |> ignore

        rec_hrule(exp)

        // 2. Explicit export settings: Format / Quality (or GIF FPS) / Resolution
        exp.box(fn(form) {
          form.gap(Is(8.0)).lines_up(Is(Some(Start))).shrink(Is(0.0)) |> ignore

          // Format row: MP4 H.265 | MP4 H.264 | GIF
          rec_form_row(form, "格式", fn(opts) {
            rec_seg_pill(opts, fn() { "MP4 · H.265" }, fn() { rec_exp_fmt.get() == 0 }, fn() {
              rec_exp_fmt.set(0)
              if rec_exp_scale.untracked() == 854 {
                rec_exp_scale.set(0)
              }
            })
            rec_seg_pill(opts, fn() { "MP4 · H.264" }, fn() { rec_exp_fmt.get() == 1 }, fn() {
              rec_exp_fmt.set(1)
              if rec_exp_scale.untracked() == 854 {
                rec_exp_scale.set(0)
              }
            })
            rec_seg_pill(opts, fn() { "GIF" }, fn() { rec_exp_fmt.get() == 2 }, fn() {
              rec_exp_fmt.set(2)
              if rec_exp_scale.untracked() == 0 {
                rec_exp_scale.set(1280)
              }
            })
          })

          // Quality row (MP4)
          form.show(fn() { rec_exp_fmt.get() != 2 }, fn(qwrap) {
            qwrap.shrink(Is(0.0)) |> ignore
            rec_form_row(qwrap, "质量", fn(opts) {
              rec_seg_pill(opts, fn() { tr("原画") }, fn() { rec_exp_qual.get() == 0 }, fn() { rec_exp_qual.set(0) })
              rec_seg_pill(opts, fn() { tr("高画质") }, fn() { rec_exp_qual.get() == 1 }, fn() { rec_exp_qual.set(1) })
              rec_seg_pill(opts, fn() { tr("标准") }, fn() { rec_exp_qual.get() == 2 }, fn() { rec_exp_qual.set(2) })
              rec_seg_pill(opts, fn() { tr("小体积") }, fn() { rec_exp_qual.get() == 3 }, fn() { rec_exp_qual.set(3) })
            })
          }, at_once=true)

          // FPS row (GIF)
          form.show(fn() { rec_exp_fmt.get() == 2 }, fn(fwrap) {
            fwrap.shrink(Is(0.0)) |> ignore
            rec_form_row(fwrap, "帧率", fn(opts) {
              rec_seg_pill(opts, fn() { "10 fps" }, fn() { rec_exp_gif_fps.get() == 10 }, fn() { rec_exp_gif_fps.set(10) })
              rec_seg_pill(opts, fn() { "15 fps" }, fn() { rec_exp_gif_fps.get() == 15 }, fn() { rec_exp_gif_fps.set(15) })
              rec_seg_pill(opts, fn() { "20 fps" }, fn() { rec_exp_gif_fps.get() == 20 }, fn() { rec_exp_gif_fps.set(20) })
            })
          }, at_once=true)

          // Resolution / Scale row
          rec_form_row(form, "尺寸", fn(opts) {
            rec_seg_pill(opts, fn() { tr("原始") }, fn() { rec_exp_scale.get() == 0 }, fn() { rec_exp_scale.set(0) })
            rec_seg_pill(opts, fn() { "1080p" }, fn() { rec_exp_scale.get() == 1920 }, fn() { rec_exp_scale.set(1920) })
            rec_seg_pill(opts, fn() { "720p" }, fn() { rec_exp_scale.get() == 1280 }, fn() { rec_exp_scale.set(1280) })
            opts.show(fn() { rec_exp_fmt.get() == 2 }, fn(g480) {
              g480.shrink(Is(0.0)) |> ignore
              rec_seg_pill(g480, fn() { "480p" }, fn() { rec_exp_scale.get() == 854 }, fn() { rec_exp_scale.set(854) })
            }, at_once=true)
          })
        })
        |> ignore

        rec_hrule(exp)

        // 3. Bottom status/spec/progress + Save As / Save & Copy
        exp.box(fn(foot) {
          foot.row(Is(true)).gap(Is(10.0)).height(Is(Some(32.0))).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore

          foot.box(fn(st) {
            st.row(Is(true)).gap(Is(8.0)).grow(Is(1.0)).lines_up(Is(Some(Middle))) |> ignore
            st.box(fn(w) {
              w
              .shrink(Is(0.0))
              .words(
                By(fn() {
                  match rec_phase.get() {
                    5 => tr("正在编码 ") + rec_exp_pct.get().to_string() + "%"
                    6 => tr("已保存 · ") + rec_fmt_size(rec_exp_bytes.get()) + rec_saved_pct_tag()
                    7 => rec_err.get()
                    _ => rec_spec_summary()
                  }
                }),
                look={ ..@view.words_plain, size: 12.0, weight: 500, line: 16.0, wrap: false },
              )
              .ink(By(fn() {
                match rec_phase.get() {
                  6 => 0x4CC38AFFL
                  7 => 0xF5A524FFL
                  5 => 0x88C8FFFFL
                  _ => 0x9EA3ABFFL
                }
              }))
              |> ignore
            })
            |> ignore
            st.show(fn() { rec_phase.get() == 6 }, fn(op) {
              op
              .height(Is(Some(24.0)))
              .shrink(Is(0.0))
              .padding(Is((8.0, 0.0, 8.0, 0.0)))
              .radius(Is(6.0))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              .presses(Is(true))
              .cursor(Is(Some(Hand)))
              .says(By(fn() { Some(@view.said(Button, label=tr("打开位置"))) }))
              .on_press(fn() {
                let p = rec_path.untracked()
                if p != "" {
                  ps_reveal(cstr(p))
                }
              })
              .ground(By(fn() { if op.pointed() { 0xFFFFFF22L } else { 0xFFFFFF12L } }))
              |> ignore
              op.box(fn(t) {
                t
                .shrink(Is(0.0))
                .words(By(fn() { tr("打开位置") }), look={
                  ..@view.words_plain,
                  size: 11.5,
                  weight: 500,
                  line: 15.0,
                  wrap: false,
                })
                .ink(Is(0xECEEF2FFL))
                |> ignore
              })
              |> ignore
            }, at_once=true)
          })
          |> ignore

          rec_action_btn(
            foot,
            None,
            None,
            fn() { tr("另存为…") },
            0xFFFFFF16L,
            0xFFFFFF24L,
            0xFFFFFF30L,
            fn() { rec_run_export(true) },
            dim=fn() { rec_phase.get() == 5 },
          )
          rec_action_btn(
            foot,
            None,
            Some("check"),
            fn() { if rec_phase.get() == 5 { tr("编码中…") } else { tr("保存并复制") } },
            accent,
            0x48A8FFFFL,
            0x1F7FDDFFL,
            fn() { rec_run_export(false) },
            dim=fn() { rec_phase.get() == 5 },
          )
        })
        |> ignore
      }, at_once=true)
    })
    |> ignore
  })
  |> ignore
}
