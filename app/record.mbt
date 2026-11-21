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
#borrow(src_path, dst_path)
extern "C" fn ps_rec_reuse(src_path : Bytes, dst_path : Bytes) -> Int = "ps_rec_reuse"

///|
extern "C" fn ps_rec_has_av1() -> Int = "ps_rec_has_av1"

///|
extern "C" fn ps_rec_export_cancel() -> Unit = "ps_rec_export_cancel"

///|
extern "C" fn ps_rec_preview() -> Bytes = "ps_rec_preview"

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
let rec_from_bar : Ref[(Double, Double, Double, Double)?] = Ref(None)

///|
/// True while the recording bar stays anchored to the screenshot toolbar's right edge (cleared once dragged by hand).
let rec_anchor_right : @signals.Signal[Bool] = @signals.signal(false)

///|
let rec_handoff_cancel : Ref[() -> Unit] = Ref(fn() {  })

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
/// fmt: 0 = MP4 H.265, 1 = MP4 H.264, 2 = GIF, 3 = MP4 AV1
let rec_exp_fmt : @signals.Signal[Int] = @signals.signal(0)

///|
/// quality: 0 = Original, 1 = High, 2 = Balanced (default), 3 = Compact
let rec_exp_qual : @signals.Signal[Int] = @signals.signal(2)

///|
/// MP4 scale: 0 = 100%, 75 = 75%, 50 = 50%
let rec_exp_scale : @signals.Signal[Int] = @signals.signal(0)

///|
/// GIF max long edge: 1080 = <=1080px (default), 720 = <=720px, 0 = Original (100%)
let rec_exp_gif_scale : @signals.Signal[Int] = @signals.signal(1080)

///|
fn rec_active_scale(fmt : Int) -> Int {
  if fmt == 2 { rec_exp_gif_scale.get() } else { rec_exp_scale.get() }
}

///|
fn rec_active_scale_now(fmt : Int) -> Int {
  if fmt == 2 { rec_exp_gif_scale.untracked() } else { rec_exp_scale.untracked() }
}

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
/// Exported files cached for the current recording: canonical combo key -> (path, bytes).
let rec_exports : Map[String, (String, Double)] = Map([])

///|
let rec_exports_ver : @signals.Signal[Int] = @signals.signal(0)

///|
let rec_exporting_key : Ref[String] = Ref("")

///|
let rec_copied_note : @signals.Signal[Bool] = @signals.signal(false)

///|
let rec_has_av1 : @signals.Signal[Bool] = @signals.signal(false)

///|
let rec_preview_key : @signals.Signal[String] = @signals.signal("")

///|
let rec_preview_seq : Ref[Int] = Ref(0)

///|
/// Transparent shadow halo around the floating superellipse card (L, T, R, B points, >= 3*sigma so alpha reaches 0 before every window edge).
let rec_pad_l : Double = 30.0

///|
let rec_pad_t : Double = 26.0

///|
let rec_pad_r : Double = 30.0

///|
let rec_pad_b : Double = 36.0

///|
fn rec_combo_key(fmt : Int, qual : Int, max_side : Int, gif_fps : Int) -> String {
  let (ow, oh) = rec_out_dims(max_side)
  if fmt == 2 {
    "gif:\{ow}x\{oh}@\{gif_fps}"
  } else {
    "mp4:\{fmt}:\{qual}:\{ow}x\{oh}"
  }
}

///|
fn rec_current_key() -> String {
  let fmt = rec_exp_fmt.untracked()
  rec_combo_key(
    fmt,
    rec_exp_qual.untracked(),
    rec_active_scale_now(fmt),
    rec_exp_gif_fps.untracked(),
  )
}

///|
fn rec_has_exported_fmt(fmt : Int) -> Bool {
  rec_exports_ver.get() |> ignore
  let prefix = if fmt == 2 { "gif:" } else { "mp4:\{fmt}:" }
  for k, _ in rec_exports {
    if k.has_prefix(prefix) {
      return true
    }
  }
  false
}

///|
fn rec_has_exported_combo(fmt : Int, qual : Int, max_side : Int, gif_fps : Int) -> Bool {
  rec_exports_ver.get() |> ignore
  rec_exports.contains(rec_combo_key(fmt, qual, max_side, gif_fps))
}

///|
fn rec_clear_preview() -> Unit {
  let old = rec_preview_key.untracked()
  if old != "" {
    @ui.forget_image(old)
    rec_preview_key.set("")
  }
}

///|
fn rec_load_preview() -> Unit {
  rec_clear_preview()
  let b = ps_rec_preview()
  if b.length() > 54 {
    rec_preview_seq.val += 1
    let key = "mem:rec-prev-\{rec_preview_seq.val}"
    @ui.add_image(key, b)
    rec_preview_key.set(key)
  }
}

///|
fn rec_clear_exports() -> Unit {
  rec_exports.clear()
  rec_exporting_key.val = ""
  rec_copied_note.set(false)
  rec_exports_ver.set(rec_exports_ver.untracked() + 1)
}

///|
fn rec_sync_combo_state() -> Unit {
  if rec_phase.untracked() == 5 {
    return
  }
  let key = rec_current_key()
  match rec_exports.get(key) {
    Some((p, b)) => {
      @signals.start_batch()
      rec_path.set(p)
      rec_exp_bytes.set(b)
      rec_copied_note.set(false)
      rec_phase.set(6)
      @signals.end_batch()
    }
    None => {
      @signals.start_batch()
      rec_copied_note.set(false)
      if rec_phase.untracked() == 6 || rec_phase.untracked() == 7 {
        rec_phase.set(4)
      }
      @signals.end_batch()
    }
  }
}

///|
fn rec_out_dims(scale_param : Int) -> (Int, Int) {
  let sw = rec_part.val.w
  let sh = rec_part.val.h
  if scale_param <= 0 || scale_param == 100 || sw <= 0 || sh <= 0 {
    (sw, sh)
  } else if scale_param < 100 {
    let k = scale_param.to_double() / 100.0
    let ow = clampi(((sw.to_double() * k + 0.5).to_int()) & -2, 16, sw)
    let oh = clampi(((sh.to_double() * k + 0.5).to_int()) & -2, 16, sh)
    (ow, oh)
  } else if sw <= scale_param && sh <= scale_param {
    (sw, sh)
  } else {
    let long = if sw > sh { sw } else { sh }
    let k = scale_param.to_double() / long.to_double()
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
/// codec_mode: 0 = H.265, 1 = H.264, 3 = AV1
fn rec_target_bps(codec_mode : Int, qual : Int, w : Int, h : Int, fps : Int) -> Double {
  let ef = rec_eff_fps(fps)
  let px = w.to_double() * h.to_double() * ef
  let qi = clampi(qual, 0, 3)
  if codec_mode == 3 {
    let bpp = [0.056, 0.036, 0.018, 0.0085][qi]
    let lo = [650000.0, 400000.0, 200000.0, 110000.0][qi]
    let hi = [12000000.0, 6000000.0, 2600000.0, 1100000.0][qi]
    clamp(px * bpp, lo, hi)
  } else if codec_mode == 0 {
    let bpp = [0.075, 0.048, 0.024, 0.011][qi]
    let lo = [900000.0, 550000.0, 280000.0, 150000.0][qi]
    let hi = [16000000.0, 8000000.0, 3500000.0, 1500000.0][qi]
    clamp(px * bpp, lo, hi)
  } else {
    let bpp = [0.115, 0.072, 0.038, 0.018][qi]
    let lo = [1300000.0, 800000.0, 420000.0, 220000.0][qi]
    let hi = [24000000.0, 12000000.0, 5200000.0, 2200000.0][qi]
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
  let master_codec = if rec_codec.get().has_prefix("HEVC") { 0 } else { 1 }
  let master_bps = rec_target_bps(master_codec, 0, sw, sh, fps)
  let (ow, oh) = rec_out_dims(max_side)
  if fmt == 2 {
    // GIF with proper dirty-rect transparency & frame merge
    let master_cap = dmax(1.0, master_bps * dur_s / 8.0)
    let activity = clamp(master_vid / master_cap, 0.08, 1.0)
    let raw_gif = ow.to_double() * oh.to_double() * gif_fps.to_double() * dur_s * (0.014 + 0.075 * activity)
    dmax(12288.0, raw_gif)
  } else {
    let out_bps = rec_target_bps(fmt, qual, ow, oh, fps)
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
  let from_bar = toolbar_main_rect()
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
  rec_from_bar.val = from_bar
  rec_placed_size.val = (0, 0)
  @signals.start_batch()
  rec_anchor_right.set(from_bar is Some(_))
  rec_phase.set(if from_bar is Some(_) { -1 } else { 0 })
  rec_ms.set(0)
  rec_frames.set(0)
  rec_master_bytes.set(0.0)
  rec_master_audio.set(false)
  rec_exp_bytes.set(0.0)
  rec_exp_pct.set(0)
  rec_codec.set("")
  rec_path.set("")
  rec_err.set("")
  rec_clear_exports()
  rec_clear_preview()
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
  let cloaked = @ui.env("PINSHOT_TEST_CLOAKED") != ""
  if cloaked {
    ps_cloak(wid, 1)
  }
  rec_place_initial(360.0 + rec_pad_l + rec_pad_r, bar_height + rec_pad_t + rec_pad_b, !cloaked)
  if from_bar is None {
    rec_schedule_fit(!cloaked)
  }
  log("rec: ready \{part.w}x\{part.h} at \{part.x},\{part.y}")
}

///|
/// Initial placement under (or over, or centered on) the selected region, accounting for the transparent shadow halo.
fn rec_place_initial(pt_w : Double, pt_h : Double, focus : Bool) -> Unit {
  let m = rec_mon.val
  let k = rec_scale.val
  let (x, y, w, h) = match rec_from_bar.val {
    Some((bx, by, bw, bh)) => {
      let ww = ((bw + rec_pad_l + rec_pad_r) * k).ceil().to_int()
      let hh = ((bh + rec_pad_t + rec_pad_b) * k).ceil().to_int()
      let xx = clampi(m.x + ((bx - rec_pad_l) * k).round().to_int(), m.x, m.right() - ww)
      let yy = clampi(m.y + ((by - rec_pad_t) * k).round().to_int(), m.y, m.bottom() - hh)
      (xx, yy, ww, hh)
    }
    None => {
      let p = rec_part.val
      let ww = (pt_w * k).round().to_int()
      let hh = (pt_h * k).round().to_int()
      let gap = (8.0 * k).round().to_int()
      let pad_t = (rec_pad_t * k).round().to_int()
      let pad_b = (rec_pad_b * k).round().to_int()
      let xx = clampi(p.x + (p.w - ww) / 2, m.x, m.right() - ww)
      let yy = if p.bottom() + gap - pad_t + hh <= m.bottom() {
        p.bottom() + gap - pad_t
      } else if p.y - gap + pad_b - hh >= m.y {
        p.y - gap + pad_b - hh
      } else {
        clampi(p.y + (p.h - hh) / 2, m.y, m.bottom() - hh)
      }
      (xx, yy, ww, hh)
    }
  }
  rec_placed_size.val = (w, h)
  let do_focus = focus && @ui.env("PINSHOT_TEST_CLOAKED") == ""
  ps_place(rec_wid.val, x, y, w, h, 1, if do_focus { 1 } else { 0 })
}

///|
let rec_shrink_cancel : Ref[() -> Unit] = Ref(fn() {  })

///|
/// Measure the inner content box (including its transparent shadow halo) and resize snugly.
/// When shrinking (e.g. Ready bar -> Recording bar), defer HWND tightening until after the 185ms pill morph finishes
/// and preserve the anchored edge so the morphing superellipse never clips or jumps.
fn rec_fit_window(focus : Bool, allow_shrink? : Bool = false) -> Unit {
  if rec_wid.val == 0 || rec_phase.untracked() == -1 {
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
  let shrinking = pw > 0 && ph > 0 && (w < pw - 1 || h < ph - 1)
  if shrinking && !focus && !allow_shrink {
    (rec_shrink_cancel.val)()
    match rec_root.val {
      Some(root) =>
        rec_shrink_cancel.val = root.at_moment(
          root.cause_at() + 215.0,
          fn() {
            rec_shrink_cancel.val = fn() {  }
            rec_fit_window(false, allow_shrink=true)
          },
          later=true,
        )
      None => ()
    }
    return
  }
  (rec_shrink_cancel.val)()
  rec_shrink_cancel.val = fn() {  }
  let r = numbers_of(text_of(ps_window_rect(rec_wid.val)))
  let (x, y) = if r.length() >= 4 && r[2] > 0.0 && r[3] > 0.0 {
    let cur_x = r[0].round().to_int()
    let cur_y = r[1].round().to_int()
    if rec_anchor_right.untracked() {
      let cur_r = (r[0] + r[2]).round().to_int()
      (clampi(cur_r - w, m.x, m.right() - w), clampi(cur_y, m.y, m.bottom() - h))
    } else if shrinking {
      (clampi(cur_x, m.x, m.right() - w), clampi(cur_y, m.y, m.bottom() - h))
    } else {
      let cx = (r[0] + r[2] / 2.0).round().to_int()
      (clampi(cx - w / 2, m.x, m.right() - w), clampi(cur_y, m.y, m.bottom() - h))
    }
  } else {
    let p = rec_part.val
    (clampi(p.x + p.w / 2 - w / 2, m.x, m.right() - w), clampi(p.bottom(), m.y, m.bottom() - h))
  }
  rec_placed_size.val = (w, h)
  let do_focus = focus && @ui.env("PINSHOT_TEST_CLOAKED") == ""
  ps_place(rec_wid.val, x, y, w, h, 1, if do_focus { 1 } else { 0 })
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
  let ph = rec_phase.untracked()
  if rec_wid.val == 0 || (ph != 0 && ph != -1) {
    return
  }
  (rec_handoff_cancel.val)()
  rec_handoff_cancel.val = fn() {  }
  let fps = rec_fps.untracked()
  let cur = if rec_cursor.untracked() { 1 } else { 0 }
  let aud = if rec_audio.untracked() { 1 } else { 0 }
  @signals.start_batch()
  rec_ms.set(0)
  rec_frames.set(0)
  rec_err.set("")
  rec_clear_exports()
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
  let fmt = rec_exp_fmt.untracked()
  let qual = rec_exp_qual.untracked()
  let max_side = rec_active_scale_now(fmt)
  let gif_fps = rec_exp_gif_fps.untracked()
  let key = rec_combo_key(fmt, qual, max_side, gif_fps)
  let mut chosen_dest = ""
  match rec_exports.get(key) {
    Some((cached_path, cached_bytes)) =>
      if !ask_dialog {
        let test_out = @ui.env("PINSHOT_TEST_REC_OUT")
        let r = ps_rec_reuse(cstr(cached_path), cstr(test_out))
        if r == 1 {
          let final_path = if test_out != "" { test_out } else { cached_path }
          shutter()
          @signals.start_batch()
          rec_path.set(final_path)
          rec_exp_bytes.set(cached_bytes)
          rec_copied_note.set(true)
          rec_phase.set(6)
          @signals.end_batch()
          log("rec: reused exported \{key} -> \{final_path}")
          return
        } else if r == -1 {
          rec_err.set(tr("保存文件失败"))
          rec_phase.set(7)
          return
        } else {
          rec_exports.remove(key)
          rec_exports_ver.set(rec_exports_ver.untracked() + 1)
        }
      } else {
        chosen_dest = rec_export_dest(true)
        if chosen_dest == "" {
          return
        }
        let r = ps_rec_reuse(cstr(cached_path), cstr(chosen_dest))
        if r == 1 {
          shutter()
          rec_exports[key] = (chosen_dest, cached_bytes)
          @signals.start_batch()
          rec_exports_ver.set(rec_exports_ver.untracked() + 1)
          rec_path.set(chosen_dest)
          rec_exp_bytes.set(cached_bytes)
          rec_copied_note.set(false)
          rec_phase.set(6)
          @signals.end_batch()
          log("rec: saved-as from cached \{key} -> \{chosen_dest}")
          return
        } else if r == -1 {
          rec_err.set(tr("保存文件失败"))
          rec_phase.set(7)
          return
        } else {
          rec_exports.remove(key)
          rec_exports_ver.set(rec_exports_ver.untracked() + 1)
        }
      }
    None => ()
  }
  let dest = if chosen_dest != "" { chosen_dest } else { rec_export_dest(ask_dialog) }
  if dest == "" {
    return
  }
  rec_exporting_key.val = key
  @signals.start_batch()
  rec_path.set(dest)
  rec_exp_pct.set(0)
  rec_err.set("")
  rec_copied_note.set(false)
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
/// Whether a hardware AV1 encoder is here, as the native side knows it (-1: not yet, asked on its own thread: told
/// later as {"do":"rec-av1"}); asked only once a recording is there to export, never as the panel opens.
fn rec_av1_told(v : Int) -> Unit {
  if v < 0 {
    return
  }
  @signals.start_batch()
  rec_has_av1.set(v == 1)
  if rec_exp_fmt.untracked() == 3 && v != 1 {
    rec_exp_fmt.set(0)
  }
  @signals.end_batch()
  rec_schedule_fit(false)
}

///|
fn rec_cancel() -> Unit {
  let ph = rec_phase.untracked()
  if ph == 1 || ph == 2 {
    rec_phase.set(3)
    ps_rec_stop(1)
  } else if ph == 5 {
    // (an export under way called off alone: the recording kept, back to choosing; told "export-cancelled")
    ps_rec_export_cancel()
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
  (rec_shrink_cancel.val)()
  rec_shrink_cancel.val = fn() {  }
  (rec_handoff_cancel.val)()
  rec_handoff_cancel.val = fn() {  }
  rec_root.val = None
  rec_content.val = None
  rec_from_bar.val = None
  rec_anchor_right.set(false)
  rec_placed_size.val = (0, 0)
  rec_clear_exports()
  rec_clear_preview()
  trim_soon()
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
      rec_load_preview()
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
      rec_av1_told(ps_rec_has_av1())
      log("rec: master ready \{codec} audio=\{audio} \{frames}f \{ms}ms \{bytes}B")
    }
    "export-cancelled" => {
      @signals.start_batch()
      rec_exp_pct.set(0)
      rec_phase.set(4)
      @signals.end_batch()
      rec_schedule_fit(false)
      log("rec: export cancelled, the recording kept")
    }
    "exporting" => {
      @signals.start_batch()
      rec_phase.set(5)
      rec_exp_pct.set(pct)
      @signals.end_batch()
    }
    "exported" => {
      shutter()
      let final_path = if path != "" { path } else { rec_path.untracked() }
      let k = rec_exporting_key.val
      @signals.start_batch()
      if k != "" && final_path != "" {
        rec_exports[k] = (final_path, bytes)
        rec_exports_ver.set(rec_exports_ver.untracked() + 1)
      }
      rec_exp_bytes.set(bytes)
      if orig > 0.0 {
        rec_master_bytes.set(orig)
      }
      rec_exp_pct.set(100)
      if final_path != "" {
        rec_path.set(final_path)
      }
      rec_copied_note.set(false)
      rec_phase.set(6)
      @signals.end_batch()
      rec_schedule_fit(false)
      log("rec: exported \{codec} \{bytes}B (orig \{orig}B) -> \{final_path}")
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
      // (the recording's frame and its clicks' overlay let go: no recording runs)
      ps_rec_stop(1)
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
  let m_s = if mins < 10 { "0" + mins.to_string() } else { mins.to_string() }
  let s_s = if secs < 10 { "0" + secs.to_string() } else { secs.to_string() }
  "\{m_s}:\{s_s}"
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
fn rec_current_est_bytes() -> Double {
  let fmt = rec_exp_fmt.get()
  rec_est_bytes(fmt, rec_exp_qual.get(), rec_active_scale(fmt), rec_exp_gif_fps.get())
}

///|
fn rec_est_saved_pct() -> Int {
  let orig = rec_master_bytes.get()
  let est = rec_current_est_bytes()
  if orig > 0.0 && est > 0.0 && est < orig * 0.96 {
    let pct = ((orig - est) / orig * 100.0).round().to_int()
    if pct > 0 { pct } else { 0 }
  } else {
    0
  }
}

///|
fn rec_short_codec() -> String {
  let c = rec_codec.get()
  if c.has_prefix("HEVC") {
    "H.265"
  } else if c.has_prefix("H.264") {
    "H.264"
  } else if c.has_prefix("AV1") {
    "AV1"
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
    let hov = smooth_hover(b, live=fn() { !dim() })
    tactile_press(b, live=fn() { !dim() })
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
        mix_rgba(bg_lit, 0x2F9BFF3DL, hov())
      } else {
        mix_rgba(0L, 0xFFFFFF17L, hov())
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
        } else {
          mix_rgba(0xD6DAE0FFL, 0xFFFFFFFFL, hov())
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
    let hov = smooth_hover(b, live=fn() { !dim() })
    tactile_press(b, live=fn() { !dim() })
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
      } else {
        mix_rgba(bg, bg_hover, hov())
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
/// Crisp format tab inside the Studio HUD top strip (white active pill glides underneath via sliding_thumb).
fn rec_tab_item(
  track : @view.View,
  key : Int,
  views : Map[Int, @view.View],
  label_fn : () -> String,
  active : () -> Bool,
  press : () -> Unit,
  done_dot? : () -> Bool = fn() { false },
) -> Unit {
  track.box(fn(b) {
    views[key] = b
    let live = fn() { rec_phase.get() != 5 }
    let hov = smooth_hover(b, live~)
    let act = @motion.eased_on(b, active, @motion.tween(130.0, ease=Out))
    tactile_press(b, live~, sink_px=0.9)
    b
    .row(Is(true))
    .height(Is(Some(24.0)))
    .gap(Is(4.0))
    .padding(Is((9.0, 0.0, 9.0, 0.0)))
    .shrink(Is(0.0))
    .radius(Is(6.5))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .cursor(By(fn() { if rec_phase.get() == 5 { None } else { Some(Hand) } }))
    .says(By(fn() { Some(@view.said(Button, label=label_fn())) }))
    .on_press(fn() {
      if rec_phase.untracked() != 5 {
        press()
        rec_sync_combo_state()
        save_settings()
      }
    })
    .ground(By(fn() {
      if active() {
        0L
      } else {
        mix_rgba(0L, 0xFFFFFF0FL, hov())
      }
    }))
    |> ignore
    b.box(fn(t) {
      t
      .shrink(Is(0.0))
      .words(By(label_fn), look={ ..@view.words_plain, size: 11.0, weight: 600, line: 14.0, wrap: false })
      .ink(By(fn() {
        let rest = mix_rgba(0x838998FFL, 0xD5DAE4FFL, hov())
        mix_rgba(rest, 0x121317FFL, act.shown(t))
      }))
      |> ignore
    })
    |> ignore
    b.show(done_dot, fn(d) {
      enter_reveal(d, ms=130.0, dy=0.0, from_scale=0.4)
      d
      .width(Is(Some(4.5)))
      .height(Is(Some(4.5)))
      .shrink(Is(0.0))
      .radius(Is(2.25))
      .ground(By(fn() { mix_rgba(0x34D399FFL, 0x10B981FFL, act.shown(d)) }))
      |> ignore
    }, at_once=true)
  })
  |> ignore
}

///|
/// Borderless lightweight inline option pill (glass active pill glides smoothly underneath via sliding_thumb).
fn rec_inline_opt(
  row : @view.View,
  key : Int,
  views : Map[Int, @view.View],
  label_fn : () -> String,
  active : () -> Bool,
  press : () -> Unit,
  done_dot? : () -> Bool = fn() { false },
) -> Unit {
  row.box(fn(b) {
    views[key] = b
    let live = fn() { rec_phase.get() != 5 }
    let hov = smooth_hover(b, live~)
    let act = @motion.eased_on(b, active, @motion.tween(130.0, ease=Out))
    tactile_press(b, live~, sink_px=0.9)
    b
    .row(Is(true))
    .height(Is(Some(24.0)))
    .gap(Is(4.0))
    .padding(Is((8.5, 0.0, 8.5, 0.0)))
    .shrink(Is(0.0))
    .radius(Is(6.5))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(Is(true))
    .cursor(By(fn() { if rec_phase.get() == 5 { None } else { Some(Hand) } }))
    .says(By(fn() { Some(@view.said(Button, label=label_fn())) }))
    .on_press(fn() {
      if rec_phase.untracked() != 5 {
        press()
        rec_sync_combo_state()
        save_settings()
      }
    })
    .ground(By(fn() {
      if active() {
        0L
      } else {
        mix_rgba(0L, 0xFFFFFF0CL, hov())
      }
    }))
    |> ignore
    b.box(fn(t) {
      t
      .shrink(Is(0.0))
      .words(By(label_fn), look={ ..@view.words_plain, size: 11.5, weight: 500, line: 15.0, wrap: false })
      .ink(By(fn() {
        let rest = mix_rgba(0x838998FFL, 0xCFD4DEFFL, hov())
        mix_rgba(rest, 0xF4F6FAFFL, act.shown(t))
      }))
      |> ignore
    })
    |> ignore
    b.show(done_dot, fn(d) {
      enter_reveal(d, ms=130.0, dy=0.0, from_scale=0.4)
      d.width(Is(Some(4.5))).height(Is(Some(4.5))).shrink(Is(0.0)).radius(Is(2.25)).ground(Is(0x34D399FFL)) |> ignore
    }, at_once=true)
  })
  |> ignore
}

///|
/// Airy horizontal property row: muted label left, lightweight borderless inline pills right with gliding thumb.
fn rec_prop_row(
  parent : @view.View,
  label_key : String,
  active_key : () -> Int,
  build : (@view.View, Map[Int, @view.View]) -> Unit,
) -> Unit {
  parent.box(fn(r) {
    r.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore
    r.box(fn(t) {
      t
      .shrink(Is(0.0))
      .words(By(fn() { tr(label_key) }), look={ ..@view.words_plain, size: 11.5, weight: 400, line: 15.0, wrap: false })
      .ink(Is(0x727888FFL))
      |> ignore
    })
    |> ignore
    r.box(fn(sp) { sp.grow(Is(1.0)) |> ignore }) |> ignore
    r.box(fn(opts) {
      opts.row(Is(true)).gap(Is(2.0)).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore
      let views : Map[Int, @view.View] = Map([])
      sliding_thumb(
        opts,
        active_key,
        views,
        6.5,
        fn() { 0xFFFFFF1CL },
        extra_watch=fn() { rec_exports_ver.get() + (if english.get() { 1000 } else { 0 }) },
      )
      build(opts, views)
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
      -1 | 0 => rec_start_now()
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
      rec_exp_gif_scale.get(),
      rec_exp_gif_fps.get(),
      rec_master_audio.get(),
      rec_exports_ver.get(),
      rec_copied_note.get(),
      english.get(),
    )
  }, fn(_) { rec_schedule_fit(false) })

  // Transparent page over DirectComposition so the inner superellipse bar/panel + soft shadow float natively
  root.box(fn(page) {
    page
    .over(Is(true))
    .lines_up(By(fn() { if rec_anchor_right.get() { Some(End) } else { Some(Start) } }))
    |> ignore

    // Content wrapper including transparent shadow halo whose laid_size() drives exact window size
    page.box(fn(content) {
      rec_content.val = Some(content)
      content
      .shrink(Is(0.0))
      .padding(Is((rec_pad_l, rec_pad_t, rec_pad_r, rec_pad_b)))
      .lines_up(Is(Some(Start)))
      |> ignore

      // Unified morphing superellipse shell: smoothly reshapes across Screenshot toolbar -> Ready bar -> Recording bar -> Finalizing pill -> Studio HUD card
      content.box(fn(shell) {
        let is_exp = fn() { rec_phase.get() >= 4 }
        let exp_p = @motion.eased_on(shell, is_exp, @motion.tween(185.0, ease=Out))
        let rec_moves_ref : Ref[@motion.Moves?] = Ref(None)
        let rec_parts : Array[@view.View] = []
        let track_part = fn(v : @view.View) {
          match rec_moves_ref.val {
            Some(m) => m.moves_with(v)
            None => rec_parts.push(v)
          }
        }
        if rec_from_bar.val is None {
          enter_reveal(shell, ms=145.0, dy=4.0, from_scale=0.975)
        }
        shell
        .shrink(Is(0.0))
        .radius(By(fn() { if is_exp() { 18.0 } else { bar_corner } }))
        .ground(By(fn() { mix_rgba(0x1E1F23F7L, 0x141519F8L, exp_p.shown(shell)) }))
        .edge(By(fn() { (1.0, mix_rgba(0xFFFFFF1FL, 0xFFFFFF17L, exp_p.shown(shell))) }))
        .shadow(By(fn() { if is_exp() { (11.0, 4.0, 0x0000007AL) } else { (9.0, 3.0, 0x00000058L) } }))
        |> ignore

        // ---- Phases -1..3: Concentric superellipse floating recording bar (matches toolbar.mbt) ----
        shell.show(fn() { rec_phase.get() <= 3 }, fn(bar) {
          bar
          .row(Is(true))
          .gap(Is(bar_gap))
          .height(Is(Some(bar_height)))
          .shrink(Is(0.0))
          .padding(Is((10.0, bar_pad, bar_pad, bar_pad)))
          .lines_up(Is(Some(Middle)))
          |> ignore

          // Phase -1: 1-frame handoff footprint matching the screenshot toolbar's exact width before morphing into Phase 0
          bar.show(fn() { rec_phase.get() == -1 }, fn(ph) {
            let w = match rec_from_bar.val {
              Some((_, _, bw, _)) => dmax(0.0, bw - 10.0 - bar_pad)
              None => 360.0
            }
            ph.width(Is(Some(w))).height(Is(Some(bar_height - bar_pad * 2.0))).shrink(Is(0.0)) |> ignore
          }, at_once=true)

          // Phase 3: Finalizing master
          bar.show(fn() { rec_phase.get() == 3 }, fn(r) {
            enter_reveal(r, ms=130.0, dy=0.0, from_scale=0.97)
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
          bar.show(fn() { rec_phase.get() >= 0 && rec_phase.get() <= 2 }, fn(r) {
            if rec_from_bar.val is Some(_) {
              enter_reveal(r, ms=145.0, dy=0.0, from_scale=0.985)
            }
            r.row(Is(true)).gap(Is(bar_gap)).shrink(Is(0.0)).lines_up(Is(Some(Middle))) |> ignore

            // Draggable left status + tabular timer
            r.box(fn(drag) {
              track_part(drag)
              drag
              .row(Is(true))
              .gap(Is(7.0))
              .height(Is(Some(bar_button)))
              .shrink(Is(0.0))
              .padding(Is((0.0, 0.0, 4.0, 0.0)))
              .lines_up(Is(Some(Middle)))
              .presses(Is(true))
              .on_drag(fn(d) {
                if d.kind == Down && rec_wid.val != 0 {
                  rec_anchor_right.set(false)
                  ps_move_window(rec_wid.val)
                }
              }, whole=true)
              |> ignore
              drag.box(fn(dot) {
                let pulse = @motion.breathe_alpha(
                  dot,
                  period_ms=1100.0,
                  low=0.35,
                  resident=true,
                  still=fn() { rec_phase.get() != 1 },
                )
                dot
                .width(Is(Some(8.0)))
                .height(Is(Some(8.0)))
                .shrink(Is(0.0))
                .radius(Is(4.0))
                .alpha(By(pulse))
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
              // Fixed min-width + odometer rolling tabular timer
              drag.box(fn(tm_box) {
                tm_box.min_width(Is(Some(40.0))).shrink(Is(0.0)).lines_up(Is(Some(Start))) |> ignore
                rolling_label(
                  tm_box,
                  fn() { (rec_ms.get() / 1000).to_double() },
                  fn(sec) { rec_fmt_time(sec.to_int() * 1000) },
                  13.0,
                  18.0,
                  600,
                  fn() { if rec_phase.get() == 0 { 0xB8BDC6FFL } else { 0xFFFFFFFFL } },
                )
              })
              |> ignore
            })
            |> ignore

            // FPS / codec pill (clickable in Ready to switch 30 / 60fps; persisted in settings.json)
            r.box(fn(fps_b) {
              track_part(fps_b)
              let hov = smooth_hover(fps_b, live=fn() { rec_phase.get() == 0 })
              tactile_press(fps_b, live=fn() { rec_phase.get() == 0 }, sink_px=0.9)
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
              .ground(By(fn() { mix_rgba(0xFFFFFF10L, 0xFFFFFF1CL, hov()) }))
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
            r.show(fn() { rec_phase.get() == 1 || rec_phase.get() == 2 }, fn(pb) {
              enter_reveal(pb, ms=130.0, dy=0.0, from_scale=0.92)
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
            // Right-edge action pair (constant width -> rides lock-step 4pt inside the morphing pill right edge!)
            r.box(fn(acts) {
              track_part(acts)
              acts.row(Is(true)).gap(Is(bar_gap)).shrink(Is(0.0)).lines_up(Is(Some(Middle))) |> ignore
              rec_icon_btn(acts, fn() { "close" }, fn() { tr("取消 Esc") }, fn() { false }, rec_cancel)
              acts.show(fn() { rec_phase.get() == 0 }, fn(sb) {
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
              acts.show(fn() { rec_phase.get() == 1 || rec_phase.get() == 2 }, fn(sb) {
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
            })
            |> ignore
          }, at_once=true)
        }, at_once=true)

        // ---- Phases 4..7: Landscape Studio HUD floating export card (456 x ~204pt) ----
        shell.show(fn() { rec_phase.get() >= 4 }, fn(exp) {
          enter_reveal(exp, ms=165.0, dy=0.0, from_scale=0.985)
          exp
          .row(Is(true))
          .gap(Is(12.0))
          .width(Is(Some(456.0)))
          .shrink(Is(0.0))
          .padding(Is((10.0, 10.0, 10.0, 10.0)))
          .lines_up(Is(Some(Middle)))
          |> ignore

        // 1. Left: Rounded full-bleed first-frame clip card (158 x 184pt, draggable)
        exp.box(fn(left) {
          left
          .width(Is(Some(158.0)))
          .height(Is(Some(184.0)))
          .shrink(Is(0.0))
          .radius(Is(11.0))
          .clips(Is(true))
          .ground(Is(0x0E1015FFL))
          .edge(Is((1.0, 0xFFFFFF14L)))
          .presses(Is(true))
          .on_drag(fn(d) {
            if d.kind == Down && rec_wid.val != 0 {
              rec_anchor_right.set(false)
              ps_move_window(rec_wid.val)
            }
          }, whole=true)
          |> ignore

          // Full-bleed cover preview (with silky bottom dark scrim composited in build_preview_bmp)
          left.box(fn(pic) {
            pic
            .over(Is(true))
            .presses(Is(false))
            .image(By(fn() {
              let k = rec_preview_key.get()
              if k != "" { Some((k, "", 384)) } else { None }
            }))
            .image_contains(Is(false))
            .image_fades(Is(false))
            |> ignore
          })
          |> ignore

          // Crisp bottom metadata overlay: timecode + audio + source size, and live dimensions
          left.box(fn(ov) {
            ov
            .over(Is(true))
            .lies_along(Is(End))
            .padding(Is((10.0, 8.0, 10.0, 9.0)))
            .gap(Is(2.0))
            .presses(Is(false))
            |> ignore

            ov.box(fn(r1) {
              r1.row(Is(true)).gap(Is(5.0)).lines_up(Is(Some(Middle))).shrink(Is(0.0)).presses(Is(false)) |> ignore
              r1.box(fn(tm) {
                tm
                .shrink(Is(0.0))
                .words(By(fn() { rec_fmt_time(rec_ms.get()) }), look={
                  ..@view.words_plain,
                  size: 12.0,
                  weight: 600,
                  line: 15.0,
                  wrap: false,
                })
                .ink(Is(0xFFFFFFFFL))
                |> ignore
              })
              |> ignore
              r1.show(fn() { rec_master_audio.get() }, fn(sp_icon) {
                sp_icon
                .width(Is(Some(11.0)))
                .height(Is(Some(11.0)))
                .shrink(Is(0.0))
                .picture(Is(Some(glyph("speaker"))))
                .tint(Is(0x93C5FDFFL))
                |> ignore
              }, at_once=true)
              r1.box(fn(sp) { sp.grow(Is(1.0)).presses(Is(false)) |> ignore }) |> ignore
              r1.box(fn(sz) {
                sz
                .shrink(Is(0.0))
                .words(By(fn() { rec_fmt_size(rec_master_bytes.get()) }), look={
                  ..@view.words_plain,
                  size: 10.0,
                  weight: 500,
                  line: 13.0,
                  wrap: false,
                })
                .ink(Is(0xFFFFFFC0L))
                |> ignore
              })
              |> ignore
            })
            |> ignore

            ov.box(fn(dm) {
              dm
              .shrink(Is(0.0))
              .words(
                By(fn() {
                  let sw = rec_part.val.w
                  let sh = rec_part.val.h
                  let (ow, oh) = rec_out_dims(rec_active_scale(rec_exp_fmt.get()))
                  if ow != sw || oh != sh {
                    "\{sw}×\{sh} → \{ow}×\{oh}"
                  } else {
                    "\{sw}×\{sh}"
                  }
                }),
                look={ ..@view.words_plain, size: 10.0, weight: 400, line: 13.0, wrap: false },
              )
              .ink(Is(0xFFFFFFB8L))
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore

        // 2. Right: Airy controls column (format tabs, borderless property rows, crisp footer)
        exp.box(fn(right) {
          right
          .grow(Is(1.0))
          .height(Is(Some(184.0)))
          .padding(Is((0.0, 2.0, 2.0, 1.0)))
          .gap(Is(8.0))
          |> ignore

          // 2a. Top row: Format pill strip (white active thumb) + draggable gap + subtle close button
          right.box(fn(top) {
            top.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore

            top.box(fn(tabs) {
              tabs
              .row(Is(true))
              .gap(Is(2.0))
              .padding(Is((2.5, 2.5, 2.5, 2.5)))
              .radius(Is(8.5))
              .ground(Is(0xFFFFFF0CL))
              .lines_up(Is(Some(Middle)))
              .shrink(Is(0.0))
              |> ignore
              let fmt_views : Map[Int, @view.View] = Map([])
              sliding_thumb(
                tabs,
                fn() { rec_exp_fmt.get() },
                fmt_views,
                6.5,
                fn() { 0xF2F3F6FFL },
                extra_watch=fn() {
                  rec_exports_ver.get() +
                  (if rec_has_av1.get() { 1000 } else { 0 }) +
                  (if english.get() { 10000 } else { 0 })
                },
              )
              rec_tab_item(
                tabs,
                0,
                fmt_views,
                fn() { "H.265" },
                fn() { rec_exp_fmt.get() == 0 },
                fn() { rec_exp_fmt.set(0) },
                done_dot=fn() { rec_has_exported_fmt(0) },
              )
              rec_tab_item(
                tabs,
                1,
                fmt_views,
                fn() { "H.264" },
                fn() { rec_exp_fmt.get() == 1 },
                fn() { rec_exp_fmt.set(1) },
                done_dot=fn() { rec_has_exported_fmt(1) },
              )
              tabs.show(fn() { rec_has_av1.get() }, fn(av1_slot) {
                av1_slot.row(Is(true)).shrink(Is(0.0)) |> ignore
                rec_tab_item(
                  av1_slot,
                  3,
                  fmt_views,
                  fn() { "AV1" },
                  fn() { rec_exp_fmt.get() == 3 },
                  fn() { rec_exp_fmt.set(3) },
                  done_dot=fn() { rec_has_exported_fmt(3) },
                )
              }, at_once=true)
              rec_tab_item(
                tabs,
                2,
                fmt_views,
                fn() { "GIF" },
                fn() { rec_exp_fmt.get() == 2 },
                fn() { rec_exp_fmt.set(2) },
                done_dot=fn() { rec_has_exported_fmt(2) },
              )
            })
            |> ignore

            top.box(fn(sp) {
              sp
              .grow(Is(1.0))
              .height(Is(Some(24.0)))
              .presses(Is(true))
              .on_drag(fn(d) {
                if d.kind == Down && rec_wid.val != 0 {
                  ps_move_window(rec_wid.val)
                }
              }, whole=true)
              |> ignore
            })
            |> ignore

            top.box(fn(cb) {
              let hov = smooth_hover(cb)
              tactile_press(cb, sink_px=0.9)
              cb
              .width(Is(Some(24.0)))
              .height(Is(Some(24.0)))
              .shrink(Is(0.0))
              .radius(Is(12.0))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              .presses(Is(true))
              .cursor(Is(Some(Hand)))
              .says(By(fn() { Some(@view.said(Button, label=tr("关闭 Esc"))) }))
              // (while it exports: that export called off, the recording kept, as Esc does)
              .on_press(fn() { if rec_phase.untracked() == 5 { rec_cancel() } else { rec_close() } })
              .ground(By(fn() { if cb.pressed() { 0xFFFFFF1EL } else { mix_rgba(0L, 0xFFFFFF12L, hov()) } }))
              |> ignore
              cb.box(fn(g) {
                g
                .width(Is(Some(11.5)))
                .height(Is(Some(11.5)))
                .picture(Is(Some(glyph("close"))))
                .tint(By(fn() { mix_rgba(0x737988FFL, 0xFFFFFFFFL, hov()) }))
                |> ignore
              })
              |> ignore
            })
            |> ignore
          })
          |> ignore

          // 2b. Middle: Airy borderless property rows (Quality/FPS + Percentage Size)
          right.box(fn(rows) {
            rows.grow(Is(1.0)).lies_along(Is(Middle)).gap(Is(8.0)) |> ignore

            // Quality row (MP4: H.265 / H.264 / AV1)
            rows.show(fn() { rec_exp_fmt.get() != 2 }, fn(qwrap) {
              enter_reveal(qwrap, ms=125.0, dy=3.0, from_scale=0.99)
              qwrap.shrink(Is(0.0)) |> ignore
              rec_prop_row(qwrap, "画质", fn() { rec_exp_qual.get() }, fn(opts, views) {
                rec_inline_opt(
                  opts,
                  0,
                  views,
                  fn() { tr("原画") },
                  fn() { rec_exp_qual.get() == 0 },
                  fn() { rec_exp_qual.set(0) },
                  done_dot=fn() { rec_has_exported_combo(rec_exp_fmt.get(), 0, rec_exp_scale.get(), rec_exp_gif_fps.get()) },
                )
                rec_inline_opt(
                  opts,
                  1,
                  views,
                  fn() { tr("高") },
                  fn() { rec_exp_qual.get() == 1 },
                  fn() { rec_exp_qual.set(1) },
                  done_dot=fn() { rec_has_exported_combo(rec_exp_fmt.get(), 1, rec_exp_scale.get(), rec_exp_gif_fps.get()) },
                )
                rec_inline_opt(
                  opts,
                  2,
                  views,
                  fn() { tr("标准") },
                  fn() { rec_exp_qual.get() == 2 },
                  fn() { rec_exp_qual.set(2) },
                  done_dot=fn() { rec_has_exported_combo(rec_exp_fmt.get(), 2, rec_exp_scale.get(), rec_exp_gif_fps.get()) },
                )
                rec_inline_opt(
                  opts,
                  3,
                  views,
                  fn() { tr("小体积") },
                  fn() { rec_exp_qual.get() == 3 },
                  fn() { rec_exp_qual.set(3) },
                  done_dot=fn() { rec_has_exported_combo(rec_exp_fmt.get(), 3, rec_exp_scale.get(), rec_exp_gif_fps.get()) },
                )
              })
            }, at_once=true)

            // FPS row (GIF)
            rows.show(fn() { rec_exp_fmt.get() == 2 }, fn(fwrap) {
              enter_reveal(fwrap, ms=125.0, dy=3.0, from_scale=0.99)
              fwrap.shrink(Is(0.0)) |> ignore
              rec_prop_row(fwrap, "帧率", fn() { rec_exp_gif_fps.get() }, fn(opts, views) {
                rec_inline_opt(
                  opts,
                  10,
                  views,
                  fn() { "10 fps" },
                  fn() { rec_exp_gif_fps.get() == 10 },
                  fn() { rec_exp_gif_fps.set(10) },
                  done_dot=fn() { rec_has_exported_combo(2, 0, rec_exp_gif_scale.get(), 10) },
                )
                rec_inline_opt(
                  opts,
                  15,
                  views,
                  fn() { "15 fps" },
                  fn() { rec_exp_gif_fps.get() == 15 },
                  fn() { rec_exp_gif_fps.set(15) },
                  done_dot=fn() { rec_has_exported_combo(2, 0, rec_exp_gif_scale.get(), 15) },
                )
                rec_inline_opt(
                  opts,
                  20,
                  views,
                  fn() { "20 fps" },
                  fn() { rec_exp_gif_fps.get() == 20 },
                  fn() { rec_exp_gif_fps.set(20) },
                  done_dot=fn() { rec_has_exported_combo(2, 0, rec_exp_gif_scale.get(), 20) },
                )
              })
            }, at_once=true)

            // Size row (MP4): Proportional scaling (100% / 75% / 50%)
            rows.show(fn() { rec_exp_fmt.get() != 2 }, fn(swrap) {
              enter_reveal(swrap, ms=125.0, dy=3.0, from_scale=0.99)
              swrap.shrink(Is(0.0)) |> ignore
              rec_prop_row(swrap, "尺寸", fn() { rec_exp_scale.get() }, fn(opts, views) {
                rec_inline_opt(
                  opts,
                  0,
                  views,
                  fn() { "100%" },
                  fn() { rec_exp_scale.get() == 0 },
                  fn() { rec_exp_scale.set(0) },
                  done_dot=fn() { rec_has_exported_combo(rec_exp_fmt.get(), rec_exp_qual.get(), 0, rec_exp_gif_fps.get()) },
                )
                rec_inline_opt(
                  opts,
                  75,
                  views,
                  fn() { "75%" },
                  fn() { rec_exp_scale.get() == 75 },
                  fn() { rec_exp_scale.set(75) },
                  done_dot=fn() { rec_has_exported_combo(rec_exp_fmt.get(), rec_exp_qual.get(), 75, rec_exp_gif_fps.get()) },
                )
                rec_inline_opt(
                  opts,
                  50,
                  views,
                  fn() { "50%" },
                  fn() { rec_exp_scale.get() == 50 },
                  fn() { rec_exp_scale.set(50) },
                  done_dot=fn() { rec_has_exported_combo(rec_exp_fmt.get(), rec_exp_qual.get(), 50, rec_exp_gif_fps.get()) },
                )
              })
            }, at_once=true)

            // Size row (GIF): Max long-edge cap (1080px default / 720px / Original 100%)
            rows.show(fn() { rec_exp_fmt.get() == 2 }, fn(gswrap) {
              enter_reveal(gswrap, ms=125.0, dy=3.0, from_scale=0.99)
              gswrap.shrink(Is(0.0)) |> ignore
              rec_prop_row(gswrap, "尺寸", fn() { rec_exp_gif_scale.get() }, fn(opts, views) {
                rec_inline_opt(
                  opts,
                  1080,
                  views,
                  fn() { "1080px" },
                  fn() { rec_exp_gif_scale.get() == 1080 },
                  fn() { rec_exp_gif_scale.set(1080) },
                  done_dot=fn() { rec_has_exported_combo(2, 0, 1080, rec_exp_gif_fps.get()) },
                )
                rec_inline_opt(
                  opts,
                  720,
                  views,
                  fn() { "720px" },
                  fn() { rec_exp_gif_scale.get() == 720 },
                  fn() { rec_exp_gif_scale.set(720) },
                  done_dot=fn() { rec_has_exported_combo(2, 0, 720, rec_exp_gif_fps.get()) },
                )
                rec_inline_opt(
                  opts,
                  0,
                  views,
                  fn() { tr("原尺寸") },
                  fn() { rec_exp_gif_scale.get() == 0 },
                  fn() { rec_exp_gif_scale.set(0) },
                  done_dot=fn() { rec_has_exported_combo(2, 0, 0, rec_exp_gif_fps.get()) },
                )
              })
            }, at_once=true)
          })
          |> ignore

          // 2c. Subtle hairline + Footer (tabular size readout left, Save As icon + White/Emerald CTA right)
          right.box(fn(ln) { ln.height(Is(Some(1.0))).ground(Is(0xFFFFFF10L)) |> ignore }) |> ignore

          right.box(fn(foot) {
            foot.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))).padding(Is((0.0, 2.0, 0.0, 0.0))).shrink(Is(0.0))
            |> ignore

            // Left: Size / progress / exported status
            foot.box(fn(st) {
              st.grow(Is(1.0)).gap(Is(1.5)).lines_up(Is(Some(Start))) |> ignore

              // Phase 4 (Ready)
              st.show(fn() { rec_phase.get() == 4 }, fn(rdy) {
                enter_reveal(rdy, ms=130.0, dy=3.0, from_scale=0.985)
                rdy.gap(Is(1.5)).lines_up(Is(Some(Start))) |> ignore
                rolling_label(
                  rdy,
                  rec_current_est_bytes,
                  fn(b) {
                    if b <= 0.0 {
                      "—"
                    } else if rec_is_direct_copy_for(
                      rec_exp_fmt.untracked(),
                      rec_exp_qual.untracked(),
                      rec_exp_scale.untracked(),
                    ) {
                      rec_fmt_size(b)
                    } else {
                      "~" + rec_fmt_size(b)
                    }
                  },
                  13.5,
                  17.0,
                  600,
                  fn() { 0xF2F4F8FFL },
                )
                rdy.box(fn(sub) {
                  sub.row(Is(true)).gap(Is(3.0)).lines_up(Is(Some(Middle))) |> ignore
                  sub.box(fn(t1) {
                    t1
                    .shrink(Is(0.0))
                    .words(
                      By(fn() {
                        let fmt = rec_exp_fmt.get()
                        let pct = rec_est_saved_pct()
                        if rec_is_direct_copy_for(fmt, rec_exp_qual.get(), rec_exp_scale.get()) {
                          tr("零重编码直出")
                        } else if pct > 0 {
                          tr("较原文件 ")
                        } else if fmt == 2 {
                          tr("GIF 动画")
                        } else if fmt == 3 {
                          "MP4 · AV1"
                        } else if fmt == 0 {
                          "MP4 · H.265"
                        } else {
                          "MP4 · H.264"
                        }
                      }),
                      look={ ..@view.words_plain, size: 10.5, weight: 400, line: 13.0, wrap: false },
                    )
                    .ink(Is(0x6E7484FFL))
                    |> ignore
                  })
                  |> ignore
                  sub.show(
                    fn() {
                      !rec_is_direct_copy_for(rec_exp_fmt.get(), rec_exp_qual.get(), rec_exp_scale.get()) &&
                      rec_est_saved_pct() > 0
                    },
                    fn(pc) {
                      pc
                      .shrink(Is(0.0))
                      .words(By(fn() { "-\{rec_est_saved_pct()}%" }), look={
                        ..@view.words_plain,
                        size: 10.5,
                        weight: 500,
                        line: 13.0,
                        wrap: false,
                      })
                      .ink(Is(0x34D399FFL))
                      |> ignore
                    },
                    at_once=true,
                  )
                })
                |> ignore
              }, at_once=true)

              // Phase 5 (Encoding)
              st.show(fn() { rec_phase.get() == 5 }, fn(enc) {
                enter_reveal(enc, ms=130.0, dy=3.0, from_scale=0.985)
                enc.gap(Is(5.0)).lines_up(Is(Some(Start))) |> ignore
                let prog_w = @motion.NodeWay::new(dmax(4.0, 104.0 * rec_exp_pct.untracked().to_double() / 100.0))
                enc.reacts(fn() { rec_exp_pct.get() }, at_start=false, fn(p) {
                  prog_w.go_ms(enc, dmax(4.0, 104.0 * p.to_double() / 100.0), 160.0)
                })
                enc.box(fn(t) {
                  t
                  .shrink(Is(0.0))
                  .words(By(fn() { tr("正在编码 ") + rec_exp_pct.get().to_string() + "%" }), look={
                    ..@view.words_plain,
                    size: 12.0,
                    weight: 500,
                    line: 15.0,
                    wrap: false,
                  })
                  .ink(Is(0xE8ECF4FFL))
                  |> ignore
                })
                |> ignore
                enc.box(fn(bar_bg) {
                  bar_bg.width(Is(Some(104.0))).height(Is(Some(3.5))).radius(Is(1.75)).ground(Is(0xFFFFFF16L)).clips(Is(true))
                  |> ignore
                  bar_bg.box(fn(bar_fg) {
                    bar_fg
                    .height(Is(Some(3.5)))
                    .width(Is(Some(0.0)))
                    .radius(Is(1.75))
                    .ground(Is(0xF2F3F6FFL))
                    .ground_drawn(By(fn() {
                      { dx: 0.0, dy: 0.0, dw: prog_w.shown(bar_fg), dh: 0.0, corners: None }
                    }))
                    |> ignore
                  })
                  |> ignore
                })
                |> ignore
              }, at_once=true)

              // Phase 6 (Exported / Reused)
              st.show(fn() { rec_phase.get() == 6 }, fn(done_v) {
                enter_reveal(done_v, ms=140.0, dy=3.0, from_scale=0.985)
                done_v.gap(Is(1.5)).lines_up(Is(Some(Start))) |> ignore
                rolling_label(
                  done_v,
                  fn() { rec_exp_bytes.get() },
                  rec_fmt_size,
                  13.5,
                  17.0,
                  600,
                  fn() { 0x4ADE80FFL },
                )
                done_v.box(fn(sub) {
                  sub.row(Is(true)).gap(Is(3.0)).lines_up(Is(Some(Middle))) |> ignore
                  sub.box(fn(t) {
                    t
                    .shrink(Is(0.0))
                    .words(
                      By(fn() { if rec_copied_note.get() { tr("已复制 · ") } else { tr("已导出 · ") } }),
                      look={ ..@view.words_plain, size: 10.5, weight: 400, line: 13.0, wrap: false },
                    )
                    .ink(Is(0x6E7484FFL))
                    |> ignore
                  })
                  |> ignore
                  sub.box(fn(op) {
                    let hov = smooth_hover(op)
                    op
                    .shrink(Is(0.0))
                    .presses(Is(true))
                    .cursor(Is(Some(Hand)))
                    .says(By(fn() { Some(@view.said(Button, label=tr("打开位置"))) }))
                    .on_press(fn() {
                      let p = rec_path.untracked()
                      if p != "" {
                        ps_reveal(cstr(p))
                      }
                    })
                    |> ignore
                    op.box(fn(t) {
                      t
                      .shrink(Is(0.0))
                      .words(By(fn() { tr("打开位置") + " ↗" }), look={
                        ..@view.words_plain,
                        size: 10.5,
                        weight: 500,
                        line: 13.0,
                        wrap: false,
                      })
                      .ink(By(fn() { mix_rgba(0xA6AEBEFFL, 0xFFFFFFFFL, hov()) }))
                      |> ignore
                    })
                    |> ignore
                  })
                  |> ignore
                })
                |> ignore
              }, at_once=true)

              // Phase 7 (Error)
              st.show(fn() { rec_phase.get() == 7 }, fn(err_v) {
                enter_reveal(err_v, ms=130.0, dy=3.0, from_scale=0.985)
                err_v
                .shrink(Is(0.0))
                .words(By(fn() { rec_err.get() }), look={
                  ..@view.words_plain,
                  size: 11.0,
                  weight: 500,
                  line: 15.0,
                  wrap: false,
                })
                .ink(Is(0xF87171FFL))
                |> ignore
              }, at_once=true)
            })
            |> ignore

            // Right: Square icon Save As button + Crisp alabaster white (or translucent emerald) primary CTA
            foot.box(fn(btns) {
              btns.row(Is(true)).gap(Is(6.0)).shrink(Is(0.0)).lines_up(Is(Some(Middle))) |> ignore

              btns.box(fn(sa) {
                let live = fn() { rec_phase.get() != 5 }
                let hov = smooth_hover(sa, live~)
                tactile_press(sa, live~)
                sa
                .width(Is(Some(32.0)))
                .height(Is(Some(32.0)))
                .shrink(Is(0.0))
                .radius(Is(9.0))
                .lines_up(Is(Some(Middle)))
                .lies_along(Is(Middle))
                .presses(Is(true))
                .cursor(By(fn() { if rec_phase.get() == 5 { None } else { Some(Hand) } }))
                .says(By(fn() { Some(@view.said(Button, label=tr("另存为"))) }))
                .on_press(fn() { if rec_phase.untracked() != 5 { rec_run_export(true) } })
                .ground(By(fn() {
                  if rec_phase.get() == 5 {
                    0xFFFFFF08L
                  } else if sa.pressed() {
                    0xFFFFFF22L
                  } else {
                    mix_rgba(0xFFFFFF0FL, 0xFFFFFF18L, hov())
                  }
                }))
                .edge(Is((1.0, 0xFFFFFF12L)))
                |> ignore
                sa.box(fn(g) {
                  g
                  .width(Is(Some(14.5)))
                  .height(Is(Some(14.5)))
                  .picture(Is(Some(glyph("save"))))
                  .tint(By(fn() {
                    if rec_phase.get() == 5 {
                      0xFFFFFF40L
                    } else {
                      mix_rgba(0xC4CAD8FFL, 0xFFFFFFFFL, hov())
                    }
                  }))
                  |> ignore
                })
                |> ignore
              })
              |> ignore

              btns.box(fn(pri) {
                let live = fn() { rec_phase.get() != 5 }
                let hov = smooth_hover(pri, live~)
                let ok_p = @motion.eased_on(pri, fn() { rec_phase.get() == 6 }, @motion.tween(160.0, ease=Out))
                tactile_press(pri, live~)
                pri
                .row(Is(true))
                .gap(Is(5.5))
                .height(Is(Some(32.0)))
                .shrink(Is(0.0))
                .padding(Is((13.0, 0.0, 13.0, 0.0)))
                .radius(Is(9.0))
                .lines_up(Is(Some(Middle)))
                .lies_along(Is(Middle))
                .presses(Is(true))
                .cursor(By(fn() { if rec_phase.get() == 5 { None } else { Some(Hand) } }))
                .says(By(fn() {
                  Some(@view.said(Button, label=if rec_phase.get() == 6 { tr("复制文件") } else { tr("保存并复制") }))
                }))
                .on_press(fn() { if rec_phase.untracked() != 5 { rec_run_export(false) } })
                .ground(By(fn() {
                  if rec_phase.get() == 5 {
                    0xFFFFFF12L
                  } else {
                    let p = ok_p.shown(pri)
                    let rdy_bg = if pri.pressed() { 0xDDE0E6FFL } else { mix_rgba(0xF3F4F6FFL, 0xFFFFFFFFL, hov()) }
                    let ok_bg = if pri.pressed() { 0x34D39944L } else { mix_rgba(0x34D39924L, 0x34D39934L, hov()) }
                    mix_rgba(rdy_bg, ok_bg, p)
                  }
                }))
                .edge(By(fn() {
                  let p = ok_p.shown(pri)
                  if p > 0.01 { (1.0, mix_rgba(0x34D39900L, 0x34D39948L, p)) } else { (0.0, 0L) }
                }))
                |> ignore
                pri.show(fn() { rec_phase.get() != 5 }, fn(ic) {
                  ic
                  .width(Is(Some(13.0)))
                  .height(Is(Some(13.0)))
                  .shrink(Is(0.0))
                  .picture(Is(Some(glyph("copy"))))
                  .tint(By(fn() { mix_rgba(0x111216FFL, 0x6EE7B7FFL, ok_p.shown(ic)) }))
                  |> ignore
                }, at_once=true)
                pri.box(fn(t) {
                  t
                  .shrink(Is(0.0))
                  .words(
                    By(fn() {
                      match rec_phase.get() {
                        5 => tr("编码中…")
                        6 => tr("复制文件")
                        _ => tr("保存并复制")
                      }
                    }),
                    look={ ..@view.words_plain, size: 12.0, weight: 600, line: 15.0, wrap: false },
                  )
                  .ink(By(fn() {
                    if rec_phase.get() == 5 {
                      0xFFFFFF55L
                    } else {
                      mix_rgba(0x111216FFL, 0x6EE7B7FFL, ok_p.shown(t))
                    }
                  }))
                  |> ignore
                })
                |> ignore
              })
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
        }, at_once=true)

        // Register moves_for LAST so all .show() structural additions/removals complete BEFORE FLIP measures the new length/size!
        let rec_moves = @motion.moves_for(shell, fn() { rec_phase.get() }, spec=@motion.tween(185.0, ease=Out))
        rec_moves_ref.val = Some(rec_moves)
        rec_moves.reshapes(shell)
        for p in rec_parts {
          if p.alive() {
            rec_moves.moves_with(p)
          }
        }
        // Kick off the seamless morph from the screenshot toolbar's exact footprint (-1) into the Ready bar (0);
        // root.reacts on rec_phase handles deferred right-anchored HWND tightening automatically after the 185ms morph.
        if rec_phase.untracked() == -1 {
          (rec_handoff_cancel.val)()
          rec_handoff_cancel.val = root.at_moment(
            root.cause_at() + 1.0,
            fn() {
              rec_handoff_cancel.val = fn() {  }
              if rec_phase.untracked() == -1 {
                rec_phase.set(0)
              }
            },
            later=true,
          )
        }
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}
