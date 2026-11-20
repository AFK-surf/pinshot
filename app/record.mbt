// Lightweight area screen recorder & post-recording exporter (Windows):
// - Captures a selected region into a temporary high-quality MP4 via WGC + optimal GPU hardware cascade
//   (HEVC hvc1 -> H.264 HW -> H.264 SW) with optional WASAPI system audio (AAC), cursor capture, and optional
//   mouse-click ripples + keycap overlay.
// - True DirectComposition transparent window with PinShot's concentric mbui superellipse corners & soft shadow,
//   content-adaptive width/height (zero dead space, zero clipping in EN or ZH).
// - All recording & export preferences (FPS, audio, cursor, clicks/keys, format, quality, resolution, GIF fps)
//   are persisted in settings.json across runs.
// - Post-recording encoding panel with explicit Format (MP4 H.265 / MP4 H.264 / GIF), Quality (Original / High /
//   Balanced / Compact with live estimated file sizes on every option), and Size (Original / 1080p / 720p / 480p).

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
extern "C" fn ps_next_win_clear() -> Unit = "ps_next_win_clear"

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
/// Recording & export preferences (persisted in settings.json via load_settings / save_settings).
let rec_fps : @signals.Signal[Int] = @signals.signal(30)

///|
let rec_cursor : @signals.Signal[Bool] = @signals.signal(true)

///|
let rec_audio : @signals.Signal[Bool] = @signals.signal(false)

///|
let rec_input : @signals.Signal[Bool] = @signals.signal(false)

///|
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
/// Transparent shadow halo around the floating superellipse card (L, T, R, B points).
let rec_pad_l : Double = 22.0

///|
let rec_pad_t : Double = 14.0

///|
let rec_pad_r : Double = 22.0

///|
let rec_pad_b : Double = 26.0

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
fn rec_eff_fps(f : Int) -> Double {
  if f > 30 {
    30.0 + (f - 30).to_double() * 0.35
  } else {
    f.to_double()
  }
}

///|
fn rec_target_bps(hevc : Bool, qual : Int, w : Int, h : Int, fps : Int) -> Double {
  let ef = rec_eff_fps(fps)
  let px = w.to_double() * h.to_double() * ef
  if hevc {
    let bpp = [0.075, 0.048, 0.024, 0.011][clampi(qual, 0, 3)]
    let lo = [900000.0, 550000.0, 280000.0, 150000.0][clampi(qual, 0, 3)]
    let hi = [16000000.0, 8000000.0, 3500000.0, 1500000.0][clampi(qual, 0, 3)]
    clamp(px * bpp, lo, hi)
  } else {
    let bpp = [0.115, 0.072, 0.038, 0.018][clampi(qual, 0, 3)]
    let lo = [1300000.0, 800000.0, 420000.0, 220000.0][clampi(qual, 0, 3)]
    let hi = [24000000.0, 12000000.0, 5200000.0, 2200000.0][clampi(qual, 0, 3)]
    clamp(px * bpp, lo, hi)
  }
}

///|
fn rec_is_direct_copy_for(fmt : Int, qual : Int, max_side : Int) -> Bool {
  let (ow, oh) = rec_out_dims(max_side)
  let same_dim = ow == rec_part.val.w && oh == rec_part.val.h
  let master_hevc = rec_codec.get().has_prefix("HEVC")
  (fmt == 0 || fmt == 1) && qual == 0 && same_dim && ((fmt == 0) == master_hevc)
}

///|
/// Estimated output size (bytes) for any (fmt, quality, max_side, gif_fps), anchored to the actual recorded master's
/// scene complexity so PeakConstrainedVBR estimates stay realistic on both static and high-motion captures.
fn rec_est_bytes(fmt : Int, qual : Int, max_side : Int, gif_fps : Int) -> Double {
  let master = rec_master_bytes.get()
  if master <= 0.0 {
    return 0.0
  }
  if rec_is_direct_copy_for(fmt, qual, max_side) {
    return master
  }
  let dur_s = dmax(0.2, rec_ms.get().to_double() / 1000.0)
  let audio_b = if rec_master_audio.get() { dur_s * 16000.0 } else { 0.0 }
  let master_vid = dmax(4096.0, master - audio_b)
  let sw = if rec_part.val.w > 0 { rec_part.val.w } else { 1280 }
  let sh = if rec_part.val.h > 0 { rec_part.val.h } else { 720 }
  let fps = rec_fps.get()
  let master_hevc = rec_codec.get().has_prefix("HEVC")
  let master_bps = rec_target_bps(master_hevc, 0, sw, sh, fps)
  let (ow, oh) = rec_out_dims(max_side)
  if fmt == 2 {
    // GIF: scales with output pixel area, gif_fps, duration, and observed screen motion ratio
    let master_cap = dmax(1.0, master_bps * dur_s / 8.0)
    let activity = clamp(master_vid / master_cap, 0.12, 1.0)
    let raw_gif = ow.to_double() * oh.to_double() * gif_fps.to_double() * dur_s * (0.045 + 0.14 * activity)
    dmax(16384.0, raw_gif)
  } else {
    let out_bps = rec_target_bps(fmt == 0, qual, ow, oh, fps)
    let ratio = out_bps / dmax(1.0, master_bps)
    let out_cap = out_bps * dur_s / 8.0
    let scaled = master_vid * (0.22 + 0.78 * ratio)
    let est_vid = dmin(out_cap * 1.15, dmax(out_cap * 0.20, scaled))
    est_vid + audio_b
  }
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
  ps_rec_input_show(if rec_input.untracked() { 1 } else { 0 })
  ps_next_win_clear()
  let wid = @ui.window_open_here("rec")
  if wid <= 0 {
    log("rec: no window")
    ps_rec_end()
    ps_capture_open(0)
    return
  }
  rec_wid.val = wid
  ps_own(wid, 1) |> ignore
  ps_rec_exclude(wid)
  rec_place_initial(360.0 + rec_pad_l + rec_pad_r, bar_height + rec_pad_t + rec_pad_b, true)
  rec_schedule_fit(true)
  log("rec: ready \{part.w}x\{part.h} at \{part.x},\{part.y}")
}

///|
/// Initial placement under (or over, or centered on) the selected region, accounting for the transparent shadow halo.
fn rec_place_initial(pt_w : Double, pt_h : Double, focus : Bool) -> Unit {
  let m = rec_mon.val
  let k = rec_scale.val
  let p = rec_part.val
  let w = (pt_w * k).round().to_int()
  let h = (pt_h * k).round().to_int()
  let gap = (8.0 * k).round().to_int()
  let pad_t = (rec_pad_t * k).round().to_int()
  let pad_b = (rec_pad_b * k).round().to_int()
  let x = clampi(p.x + (p.w - w) / 2, m.x, m.right() - w)
  let y = if p.bottom() + gap - pad_t + h <= m.bottom() {
    p.bottom() + gap - pad_t
  } else if p.y - gap + pad_b - h >= m.y {
    p.y - gap + pad_b - h
  } else {
    clampi(p.y + (p.h - h) / 2, m.y, m.bottom() - h)
  }
  rec_placed_size.val = (w, h)
  ps_place(rec_wid.val, x, y, w, h, 1, if focus { 1 } else { 0 })
}

///|
/// Measure the inner content box (including its transparent shadow halo) and resize snugly around its center.
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
  let w = (cw * k).ceil().to_int()
  let h = (ch * k).ceil().to_int()
  let (pw, ph) = rec_placed_size.val
  if (w - pw).abs() <= 1 && (h - ph).abs() <= 1 && !focus {
    return
  }
  let r = numbers_of(text_of(ps_window_rect(rec_wid.val)))
  let (cx, top) = if r.length() >= 4 && r[2] > 0.0 && r[3] > 0.0 {
    ((r[0] + r[2] / 2.0).round().to_int(), r[1].round().to_int())
  } else {
    let p = rec_part.val
    (p.x + p.w / 2, p.bottom())
  }
  let x = clampi(cx - w / 2, m.x, m.right() - w)
  let y = clampi(top, m.y, m.bottom() - h)
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
/// Kept for protocol compatibility with native messages (no-op now that live annotations were removed).
fn rec_draw_told(_tool : Int, _count : Int) -> Unit {
  ()
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
fn rec_est_label(fmt : Int, qual : Int, max_side : Int, gif_fps : Int) -> String {
  let b = rec_est_bytes(fmt, qual, max_side, gif_fps)
  if b <= 0.0 {
    ""
  } else if rec_is_direct_copy_for(fmt, qual, max_side) {
    rec_fmt_size(b)
  } else {
    "~" + rec_fmt_size(b)
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
  let qual = rec_exp_qual.get()
  let ms = rec_exp_scale.get()
  let gfps = rec_exp_gif_fps.get()
  let (ow, oh) = rec_out_dims(ms)
  let est = rec_est_label(fmt, qual, ms, gfps)
  if fmt == 2 {
    "\{ow}×\{oh} · \{gfps}fps · \{est}"
  } else if rec_is_direct_copy_for(fmt, qual, ms) {
    let tag = if fmt == 0 { "H.265" } else { "H.264" }
    tr("零重编码直出") + " · \{tag} · \{est}"
  } else {
    let tag = if fmt == 0 { "H.265" } else { "H.264" }
    "\{ow}×\{oh} · \{tag} · \{est}"
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
/// Concentric superellipse icon button (32x32pt, r=11pt on main bar; 28x28pt, r=9pt on export header).
fn rec_icon_btn(
  row : @view.View,
  glyph_fn : () -> String,
  label_fn : () -> String,
  lit : () -> Bool,
  press : () -> Unit,
  size? : Double = bar_button,
  rad? : Double = bar_btn_corner,
  dim? : () -> Bool = fn() { false },
  tint_lit? : Int64 = 0x88C8FFFFL,
  bg_lit? : Int64 = 0x2F9BFF29L,
) -> Unit {
  row.box(fn(b) {
    b
    .width(Is(Some(size)))
    .height(Is(Some(size)))
    .shrink(Is(0.0))
    .radius(Is(rad))
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
      .width(Is(Some(16.0)))
      .height(Is(Some(16.0)))
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
  height? : Double = bar_button,
  rad? : Double = bar_btn_corner,
  dim? : () -> Bool = fn() { false },
) -> Unit {
  row.box(fn(b) {
    b
    .row(Is(true))
    .gap(Is(6.0))
    .height(Is(Some(height)))
    .shrink(Is(0.0))
    .padding(Is((12.0, 0.0, 12.0, 0.0)))
    .radius(Is(rad))
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
  sub_fn? : (() -> String)? = None,
) -> Unit {
  let has_sub = sub_fn is Some(_)
  row.box(fn(b) {
    b
    .height(Is(Some(if has_sub { 42.0 } else { 28.0 })))
    .min_width(Is(if has_sub { Some(78.0) } else { None }))
    .shrink(Is(0.0))
    .padding(Is((10.0, 0.0, 10.0, 0.0)))
    .gap(Is(1.0))
    .radius(Is(style_btn_corner))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .cursor(Is(Some(Hand)))
    .says(By(fn() { Some(@view.said(Button, label=label_fn())) }))
    .on_press(fn() {
      if rec_phase.untracked() != 5 {
        if rec_phase.untracked() == 6 {
          rec_phase.set(4)
        }
        press()
        save_settings()
      }
    })
    .ground(By(fn() {
      if active() {
        0x2F9BFF28L
      } else if b.pointed() {
        0xFFFFFF16L
      } else {
        0xFFFFFF0AL
      }
    }))
    .edge(By(fn() { if active() { (1.2, 0x2F9BFFCCL) } else { (1.0, 0xFFFFFF14L) } }))
    |> ignore
    b.box(fn(t) {
      t
      .shrink(Is(0.0))
      .words(By(label_fn), look={ ..@view.words_plain, size: 12.0, weight: 600, line: 16.0, wrap: false })
      .ink(By(fn() { if active() { 0xFFFFFFFFL } else { 0xD0D4DCFFL } }))
      |> ignore
    })
    |> ignore
    match sub_fn {
      Some(sf) =>
        b.box(fn(s) {
          s
          .shrink(Is(0.0))
          .words(By(sf), look={ ..@view.words_plain, size: 10.5, weight: 500, line: 13.0, wrap: false })
          .ink(By(fn() { if active() { 0x88C8FFFFL } else { 0x8E949EFFL } }))
          |> ignore
        })
        |> ignore
      None => ()
    }
  })
  |> ignore
}

///|
fn rec_form_row(parent : @view.View, label_key : String, build : (@view.View) -> Unit) -> Unit {
  parent.box(fn(r) {
    r.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore
    r.box(fn(lbl) {
      lbl.min_width(Is(Some(52.0))).shrink(Is(0.0)).lines_up(Is(Some(Start))) |> ignore
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

  // Transparent page over DirectComposition so the inner superellipse bar/panel + soft shadow float natively
  root.box(fn(page) {
    page.over(Is(true)).lines_up(Is(Some(Start))) |> ignore

    // Content wrapper including transparent shadow halo whose laid_size() drives exact window size
    page.box(fn(content) {
      rec_content.val = Some(content)
      content
      .shrink(Is(0.0))
      .padding(Is((rec_pad_l, rec_pad_t, rec_pad_r, rec_pad_b)))
      .lines_up(Is(Some(Start)))
      |> ignore

      // ---- Phases 0..3: Concentric superellipse floating recording bar (matches toolbar.mbt) ----
      content.show(fn() { rec_phase.get() <= 3 }, fn(bar) {
        bar_panel(bar, bar_corner)
        bar
        .row(Is(true))
        .gap(Is(bar_gap))
        .height(Is(Some(bar_height)))
        .shrink(Is(0.0))
        .padding(Is((10.0, bar_pad, bar_pad, bar_pad)))
        .lines_up(Is(Some(Middle)))
        |> ignore

        // Phase 3: Finalizing master
        bar.show(fn() { rec_phase.get() == 3 }, fn(r) {
          r
          .row(Is(true))
          .min_width(Is(Some(180.0)))
          .padding(Is((6.0, 0.0, 10.0, 0.0)))
          .shrink(Is(0.0))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
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
          r.row(Is(true)).gap(Is(bar_gap)).shrink(Is(0.0)).lines_up(Is(Some(Middle))) |> ignore

          // Draggable left status + tabular timer
          r.box(fn(drag) {
            drag
            .row(Is(true))
            .gap(Is(7.0))
            .height(Is(Some(bar_button)))
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

          // FPS / codec pill (clickable in Ready to switch 30 / 60fps; persisted in settings.json)
          r.box(fn(fps_b) {
            fps_b
            .height(Is(Some(26.0)))
            .shrink(Is(0.0))
            .padding(Is((8.0, 0.0, 8.0, 0.0)))
            .radius(Is(style_btn_corner))
            .lines_up(Is(Some(Middle)))
            .lies_along(Is(Middle))
            .presses(Is(true))
            .cursor(By(fn() { if rec_phase.get() == 0 { Some(Hand) } else { None } }))
            .says(By(fn() { Some(@view.said(Button, label="\{rec_fps.get()}fps")) }))
            .on_press(fn() {
              if rec_phase.untracked() == 0 {
                rec_fps.set(if rec_fps.untracked() == 30 { 60 } else { 30 })
                save_settings()
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
                look={ ..@view.words_plain, size: 11.5, weight: 500, line: 15.0, wrap: false },
              )
              .ink(By(fn() { if rec_phase.get() == 2 { 0xF5A524FFL } else { 0xB8BDC6FFL } }))
              |> ignore
            })
            |> ignore
          })
          |> ignore

          // Pre-recording switches (System audio, Cursor, Click & keycap overlay): hidden once recording starts
          r.show(fn() { rec_phase.get() == 0 }, fn(opts) {
            opts.row(Is(true)).gap(Is(bar_gap)).shrink(Is(0.0)).lines_up(Is(Some(Middle))) |> ignore
            rec_icon_btn(
              opts,
              fn() { if rec_audio.get() { "speaker" } else { "speaker-off" } },
              fn() { if rec_audio.get() { tr("系统声音：开") } else { tr("系统声音：关") } },
              fn() { rec_audio.get() },
              fn() {
                rec_audio.set(!rec_audio.untracked())
                save_settings()
              },
            )
            rec_icon_btn(
              opts,
              fn() { "select" },
              fn() { if rec_cursor.get() { tr("录制光标：开") } else { tr("录制光标：关") } },
              fn() { rec_cursor.get() },
              fn() {
                rec_cursor.set(!rec_cursor.untracked())
                save_settings()
              },
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
                save_settings()
              },
            )
          }, at_once=true)

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

      // ---- Phases 4..7: Superellipse post-recording encoding & quality panel ----
      content.show(fn() { rec_phase.get() >= 4 }, fn(exp) {
        exp
        .min_width(Is(Some(456.0)))
        .shrink(Is(0.0))
        .padding(Is((14.0, 12.0, 14.0, 12.0)))
        .gap(Is(10.0))
        .radius(Is(16.0))
        .ground(Is(0x1E1F23F7L))
        .edge(Is((1.0, 0xFFFFFF1FL)))
        .shadow(Is((20.0, 5.0, 0x00000078L)))
        |> ignore

        // 1. Draggable header: recorded summary + audio badge + close
        exp.box(fn(hd) {
          hd.row(Is(true)).gap(Is(10.0)).height(Is(Some(28.0))).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore
          hd.box(fn(drag) {
            drag
            .row(Is(true))
            .gap(Is(8.0))
            .grow(Is(1.0))
            .height(Is(Some(28.0)))
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
              .padding(Is((6.0, 0.0, 6.0, 0.0)))
              .radius(Is(6.0))
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
          rec_icon_btn(hd, fn() { "close" }, fn() { tr("关闭 Esc") }, fn() { false }, rec_close, size=28.0, rad=style_btn_corner)
        })
        |> ignore

        rec_hrule(exp)

        // 2. Explicit export settings: Format / Quality (with live size estimate on EVERY tier!) / Size
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

          // Quality row (MP4): EVERY option displays its estimated file size!
          form.show(fn() { rec_exp_fmt.get() != 2 }, fn(qwrap) {
            qwrap.shrink(Is(0.0)) |> ignore
            rec_form_row(qwrap, "质量", fn(opts) {
              rec_seg_pill(
                opts,
                fn() { tr("原画") },
                fn() { rec_exp_qual.get() == 0 },
                fn() { rec_exp_qual.set(0) },
                sub_fn=Some(fn() { rec_est_label(rec_exp_fmt.get(), 0, rec_exp_scale.get(), rec_exp_gif_fps.get()) }),
              )
              rec_seg_pill(
                opts,
                fn() { tr("高画质") },
                fn() { rec_exp_qual.get() == 1 },
                fn() { rec_exp_qual.set(1) },
                sub_fn=Some(fn() { rec_est_label(rec_exp_fmt.get(), 1, rec_exp_scale.get(), rec_exp_gif_fps.get()) }),
              )
              rec_seg_pill(
                opts,
                fn() { tr("标准") },
                fn() { rec_exp_qual.get() == 2 },
                fn() { rec_exp_qual.set(2) },
                sub_fn=Some(fn() { rec_est_label(rec_exp_fmt.get(), 2, rec_exp_scale.get(), rec_exp_gif_fps.get()) }),
              )
              rec_seg_pill(
                opts,
                fn() { tr("小体积") },
                fn() { rec_exp_qual.get() == 3 },
                fn() { rec_exp_qual.set(3) },
                sub_fn=Some(fn() { rec_est_label(rec_exp_fmt.get(), 3, rec_exp_scale.get(), rec_exp_gif_fps.get()) }),
              )
            })
          }, at_once=true)

          // FPS row (GIF): each FPS option also shows estimated GIF size!
          form.show(fn() { rec_exp_fmt.get() == 2 }, fn(fwrap) {
            fwrap.shrink(Is(0.0)) |> ignore
            rec_form_row(fwrap, "帧率", fn(opts) {
              rec_seg_pill(
                opts,
                fn() { "10 fps" },
                fn() { rec_exp_gif_fps.get() == 10 },
                fn() { rec_exp_gif_fps.set(10) },
                sub_fn=Some(fn() { rec_est_label(2, 0, rec_exp_scale.get(), 10) }),
              )
              rec_seg_pill(
                opts,
                fn() { "15 fps" },
                fn() { rec_exp_gif_fps.get() == 15 },
                fn() { rec_exp_gif_fps.set(15) },
                sub_fn=Some(fn() { rec_est_label(2, 0, rec_exp_scale.get(), 15) }),
              )
              rec_seg_pill(
                opts,
                fn() { "20 fps" },
                fn() { rec_exp_gif_fps.get() == 20 },
                fn() { rec_exp_gif_fps.set(20) },
                sub_fn=Some(fn() { rec_est_label(2, 0, rec_exp_scale.get(), 20) }),
              )
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

        // 3. Bottom live spec/estimate/progress + Save As / Save & Copy
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
              .radius(Is(7.0))
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
            height=30.0,
            rad=10.0,
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
            height=30.0,
            rad=10.0,
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
