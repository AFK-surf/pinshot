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
  rec_combo_key(
    rec_exp_fmt.untracked(),
    rec_exp_qual.untracked(),
    rec_exp_scale.untracked(),
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
fn rec_preview_frame_size() -> (Double, Double) {
  rec_preview_key.get() |> ignore
  let rw = rec_part.val.w.to_double()
  let rh = rec_part.val.h.to_double()
  if rw <= 0.0 || rh <= 0.0 {
    return (246.0, 118.0)
  }
  let kw = 280.0 / rw
  let kh = 118.0 / rh
  let k = if kw < kh { kw } else { kh }
  let fw = (rw * k).round()
  let fh = (rh * k).round()
  (if fw < 52.0 { 52.0 } else { fw }, if fh < 52.0 { 52.0 } else { fh })
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
  rec_clear_exports()
  rec_clear_preview()
  let av1_ok = ps_rec_has_av1() != 0
  rec_has_av1.set(av1_ok)
  if rec_exp_fmt.untracked() == 3 && !av1_ok {
    rec_exp_fmt.set(0)
  }
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
  rec_schedule_fit(!cloaked)
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
  let do_focus = focus && @ui.env("PINSHOT_TEST_CLOAKED") == ""
  ps_place(rec_wid.val, x, y, w, h, 1, if do_focus { 1 } else { 0 })
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
  let max_side = rec_exp_scale.untracked()
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
  rec_clear_exports()
  rec_clear_preview()
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
      rec_load_preview()
      let long_side = if rec_part.val.w > rec_part.val.h { rec_part.val.w } else { rec_part.val.h }
      @signals.start_batch()
      rec_ms.set(ms)
      rec_frames.set(frames)
      rec_master_bytes.set(bytes)
      rec_master_audio.set(audio != 0)
      if codec != "" {
        rec_codec.set(codec)
      }
      if rec_exp_scale.untracked() > 0 && rec_exp_scale.untracked() >= long_side {
        rec_exp_scale.set(0)
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
  rec_est_bytes(rec_exp_fmt.get(), rec_exp_qual.get(), rec_exp_scale.get(), rec_exp_gif_fps.get())
}

///|
fn rec_current_est_str() -> String {
  let fmt = rec_exp_fmt.get()
  let qual = rec_exp_qual.get()
  let ms = rec_exp_scale.get()
  let b = rec_current_est_bytes()
  if b <= 0.0 {
    "—"
  } else if rec_is_direct_copy_for(fmt, qual, ms) {
    rec_fmt_size(b)
  } else {
    "~" + rec_fmt_size(b)
  }
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
fn rec_scale_disabled(max_side : Int) -> Bool {
  if max_side <= 0 {
    return false
  }
  let long = if rec_part.val.w > rec_part.val.h { rec_part.val.w } else { rec_part.val.h }
  long > 0 && long <= max_side
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
/// Monochrome Apple/CleanShot elevated segment inside a recessed track.
fn rec_seg_item(
  track : @view.View,
  label_fn : () -> String,
  active : () -> Bool,
  press : () -> Unit,
  done_dot? : () -> Bool = fn() { false },
  disabled? : () -> Bool = fn() { false },
) -> Unit {
  track.box(fn(b) {
    b
    .row(Is(true))
    .grow(Is(1.0))
    .height(Is(Some(27.0)))
    .gap(Is(4.0))
    .padding(Is((6.0, 0.0, 6.0, 0.0)))
    .radius(Is(6.5))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .presses(By(fn() { !disabled() }))
    .cursor(By(fn() { if disabled() || rec_phase.get() == 5 { None } else { Some(Hand) } }))
    .says(By(fn() { Some(@view.said(Button, label=label_fn())) }))
    .on_press(fn() {
      if !disabled() && rec_phase.untracked() != 5 {
        press()
        rec_sync_combo_state()
        save_settings()
      }
    })
    .ground(By(fn() {
      if active() {
        0x31343CFFL
      } else if !disabled() && b.pointed() {
        0xFFFFFF0AL
      } else {
        0L
      }
    }))
    .edge(By(fn() { if active() { (0.8, 0xFFFFFF1EL) } else { (0.0, 0L) } }))
    |> ignore
    b.box(fn(t) {
      t
      .shrink(Is(0.0))
      .words(By(label_fn), look={ ..@view.words_plain, size: 11.5, weight: 600, line: 15.0, wrap: false })
      .ink(By(fn() {
        if active() {
          0xF7F8FAFFL
        } else if disabled() {
          0x474C56FFL
        } else if b.pointed() {
          0xCFD4DEFFL
        } else {
          0x8C92A0FFL
        }
      }))
      |> ignore
    })
    |> ignore
    b.show(done_dot, fn(d) {
      d.width(Is(Some(4.5))).height(Is(Some(4.5))).shrink(Is(0.0)).radius(Is(2.25)).ground(Is(0x3DD68CFFL)) |> ignore
    }, at_once=true)
  })
  |> ignore
}

///|
/// Clean horizontal Inspector row: quiet muted label on left + unified recessed segmented track on right.
fn rec_form_row(parent : @view.View, label_key : String, build : (@view.View) -> Unit) -> Unit {
  parent.box(fn(r) {
    r.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore
    r.box(fn(lbl) {
      lbl.width(Is(Some(36.0))).shrink(Is(0.0)).lines_up(Is(Some(Start))) |> ignore
      lbl.box(fn(t) {
        t
        .shrink(Is(0.0))
        .words(By(fn() { tr(label_key) }), look={ ..@view.words_plain, size: 11.5, weight: 500, line: 15.0, wrap: false })
        .ink(Is(0x7C8290FFL))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    r.box(fn(track) {
      track
      .row(Is(true))
      .grow(Is(1.0))
      .gap(Is(2.0))
      .padding(Is((3.0, 3.0, 3.0, 3.0)))
      .radius(Is(9.0))
      .ground(Is(0xFFFFFF0EL))
      .lines_up(Is(Some(Middle)))
      |> ignore
      build(track)
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
      rec_exports_ver.get(),
      rec_copied_note.get(),
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
        .shadow(Is((9.0, 3.0, 0x00000058L)))
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
              tm_box.min_width(Is(Some(40.0))).shrink(Is(0.0)).lines_up(Is(Some(Start))) |> ignore
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

      // ---- Phases 4..7: CleanShot X-style top-preview dark export card (380pt) ----
      content.show(fn() { rec_phase.get() >= 4 }, fn(exp) {
        exp
        .width(Is(Some(380.0)))
        .shrink(Is(0.0))
        .radius(Is(16.0))
        .ground(Is(0x17181CF7L))
        .edge(Is((1.0, 0xFFFFFF18L)))
        .shadow(Is((12.0, 4.0, 0x00000072L)))
        |> ignore

        // Inner clip wrapper preserves outer drop shadow while clipping top hero cleanly to r=16
        exp.box(fn(clip) {
          clip.radius(Is(16.0)).clips(Is(true)).shrink(Is(0.0)) |> ignore

          // 1. Top hero first-frame preview banner (146pt, draggable)
          clip.box(fn(hero) {
            hero
            .height(Is(Some(146.0)))
            .shrink(Is(0.0))
            .ground(Is(0x13151BFFL))
            .lines_up(Is(Some(Middle)))
            .lies_along(Is(Middle))
            .presses(Is(true))
            .cursor(Is(Some(Grab)))
            .on_drag(fn(d) {
              if d.kind == Down && rec_wid.val != 0 {
                ps_move_window(rec_wid.val)
              }
            }, whole=true)
            |> ignore

            // Centered rounded first-frame thumbnail (aspect-matched to recording)
            hero.box(fn(frame) {
              frame
              .width(By(fn() { Some(rec_preview_frame_size().0) }))
              .height(By(fn() { Some(rec_preview_frame_size().1) }))
              .radius(Is(8.0))
              .clips(Is(true))
              .ground(Is(0x0F131AFFL))
              .edge(Is((1.0, 0xFFFFFF1EL)))
              .shadow(Is((8.0, 3.0, 0x00000066L)))
              .presses(Is(false))
              |> ignore
              frame.box(fn(pic) {
                pic
                .over(Is(true))
                .presses(Is(false))
                .image(By(fn() {
                  let k = rec_preview_key.get()
                  if k != "" { Some((k, "", 720)) } else { None }
                }))
                .image_contains(Is(true))
                .image_fades(Is(false))
                |> ignore
              })
              |> ignore
            })
            |> ignore

            // Floating overlay chrome (top-right close + bottom timecode & dims/size pills)
            hero.box(fn(ov) {
              ov.over(Is(true)).padding(Is((12.0, 10.0, 12.0, 10.0))).presses(Is(false)) |> ignore

              // Top row: right-aligned translucent circular close button
              ov.box(fn(top_r) {
                top_r.row(Is(true)).lies_along(Is(End)).shrink(Is(0.0)).presses(Is(false)) |> ignore
                top_r.box(fn(cb) {
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
                  .on_press(rec_close)
                  .ground(By(fn() {
                    if cb.pressed() {
                      0x000000C0L
                    } else if cb.pointed() {
                      0x000000A6L
                    } else {
                      0x0000007AL
                    }
                  }))
                  .edge(Is((1.0, 0xFFFFFF1EL)))
                  |> ignore
                  cb.box(fn(g) {
                    g
                    .width(Is(Some(12.0)))
                    .height(Is(Some(12.0)))
                    .picture(Is(Some(glyph("close"))))
                    .tint(By(fn() { if cb.pointed() { 0xFFFFFFFFL } else { 0xC7CDD8FFL } }))
                    |> ignore
                  })
                  |> ignore
                })
                |> ignore
              })
              |> ignore

              // Flexible spacer
              ov.box(fn(sp) { sp.grow(Is(1.0)).presses(Is(false)) |> ignore }) |> ignore

              // Bottom row: timecode (+ audio indicator) left, dimensions · source size right
              ov.box(fn(bot_r) {
                bot_r.row(Is(true)).lines_up(Is(Some(Middle))).shrink(Is(0.0)).presses(Is(false)) |> ignore

                bot_r.box(fn(tm) {
                  tm
                  .row(Is(true))
                  .gap(Is(5.0))
                  .shrink(Is(0.0))
                  .padding(Is((7.0, 2.5, 7.0, 2.5)))
                  .radius(Is(6.0))
                  .ground(Is(0x0000008CL))
                  .edge(Is((1.0, 0xFFFFFF1AL)))
                  .lines_up(Is(Some(Middle)))
                  |> ignore
                  tm.box(fn(t) {
                    t
                    .shrink(Is(0.0))
                    .words(By(fn() { rec_fmt_time(rec_ms.get()) }), look={
                      ..@view.words_plain,
                      size: 11.0,
                      weight: 600,
                      line: 14.0,
                      wrap: false,
                    })
                    .ink(Is(0xF2F4F8FFL))
                    |> ignore
                  })
                  |> ignore
                  tm.show(fn() { rec_master_audio.get() }, fn(sp_icon) {
                    sp_icon
                    .width(Is(Some(11.0)))
                    .height(Is(Some(11.0)))
                    .shrink(Is(0.0))
                    .picture(Is(Some(glyph("speaker"))))
                    .tint(Is(0x88C8FFFFL))
                    |> ignore
                  }, at_once=true)
                })
                |> ignore

                bot_r.box(fn(sp) { sp.grow(Is(1.0)).presses(Is(false)) |> ignore }) |> ignore

                bot_r.box(fn(dm) {
                  dm
                  .shrink(Is(0.0))
                  .padding(Is((7.0, 2.5, 7.0, 2.5)))
                  .radius(Is(6.0))
                  .ground(Is(0x0000008CL))
                  .edge(Is((1.0, 0xFFFFFF14L)))
                  |> ignore
                  dm.box(fn(t) {
                    t
                    .shrink(Is(0.0))
                    .words(
                      By(fn() {
                        let sz = rec_fmt_size(rec_master_bytes.get())
                        "\{rec_part.val.w}×\{rec_part.val.h} · \{sz}"
                      }),
                      look={ ..@view.words_plain, size: 10.5, weight: 500, line: 14.0, wrap: false },
                    )
                    .ink(Is(0xADB4C2FFL))
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

          // Subtle divider below hero
          clip.box(fn(ln) { ln.height(Is(Some(1.0))).ground(Is(0xFFFFFF12L)) |> ignore }) |> ignore

          // 2. Body: Clean horizontal segmented controls + crisp bottom readout & CTA
          clip.box(fn(body) {
            body.padding(Is((16.0, 14.0, 16.0, 15.0))).gap(Is(9.0)).shrink(Is(0.0)) |> ignore

            // Format row: H.265 | H.264 | (AV1) | GIF
            rec_form_row(body, "格式", fn(track) {
              rec_seg_item(
                track,
                fn() { "H.265" },
                fn() { rec_exp_fmt.get() == 0 },
                fn() {
                  rec_exp_fmt.set(0)
                  if rec_exp_scale.untracked() == 854 {
                    rec_exp_scale.set(0)
                  }
                },
                done_dot=fn() { rec_has_exported_fmt(0) },
              )
              rec_seg_item(
                track,
                fn() { "H.264" },
                fn() { rec_exp_fmt.get() == 1 },
                fn() {
                  rec_exp_fmt.set(1)
                  if rec_exp_scale.untracked() == 854 {
                    rec_exp_scale.set(0)
                  }
                },
                done_dot=fn() { rec_has_exported_fmt(1) },
              )
              track.show(fn() { rec_has_av1.get() }, fn(av1_slot) {
                av1_slot.row(Is(true)).grow(Is(1.0)) |> ignore
                rec_seg_item(
                  av1_slot,
                  fn() { "AV1" },
                  fn() { rec_exp_fmt.get() == 3 },
                  fn() {
                    rec_exp_fmt.set(3)
                    if rec_exp_scale.untracked() == 854 {
                      rec_exp_scale.set(0)
                    }
                  },
                  done_dot=fn() { rec_has_exported_fmt(3) },
                )
              }, at_once=true)
              rec_seg_item(
                track,
                fn() { "GIF" },
                fn() { rec_exp_fmt.get() == 2 },
                fn() {
                  rec_exp_fmt.set(2)
                  if rec_exp_scale.untracked() == 0 && !rec_scale_disabled(1280) {
                    rec_exp_scale.set(1280)
                  }
                },
                done_dot=fn() { rec_has_exported_fmt(2) },
              )
            })

            // Quality row (MP4: H.265 / H.264 / AV1)
            body.show(fn() { rec_exp_fmt.get() != 2 }, fn(qwrap) {
              qwrap.shrink(Is(0.0)) |> ignore
              rec_form_row(qwrap, "画质", fn(track) {
                rec_seg_item(
                  track,
                  fn() { tr("原画") },
                  fn() { rec_exp_qual.get() == 0 },
                  fn() { rec_exp_qual.set(0) },
                  done_dot=fn() { rec_has_exported_combo(rec_exp_fmt.get(), 0, rec_exp_scale.get(), rec_exp_gif_fps.get()) },
                )
                rec_seg_item(
                  track,
                  fn() { tr("高画质") },
                  fn() { rec_exp_qual.get() == 1 },
                  fn() { rec_exp_qual.set(1) },
                  done_dot=fn() { rec_has_exported_combo(rec_exp_fmt.get(), 1, rec_exp_scale.get(), rec_exp_gif_fps.get()) },
                )
                rec_seg_item(
                  track,
                  fn() { tr("标准") },
                  fn() { rec_exp_qual.get() == 2 },
                  fn() { rec_exp_qual.set(2) },
                  done_dot=fn() { rec_has_exported_combo(rec_exp_fmt.get(), 2, rec_exp_scale.get(), rec_exp_gif_fps.get()) },
                )
                rec_seg_item(
                  track,
                  fn() { tr("小体积") },
                  fn() { rec_exp_qual.get() == 3 },
                  fn() { rec_exp_qual.set(3) },
                  done_dot=fn() { rec_has_exported_combo(rec_exp_fmt.get(), 3, rec_exp_scale.get(), rec_exp_gif_fps.get()) },
                )
              })
            }, at_once=true)

            // FPS row (GIF)
            body.show(fn() { rec_exp_fmt.get() == 2 }, fn(fwrap) {
              fwrap.shrink(Is(0.0)) |> ignore
              rec_form_row(fwrap, "帧率", fn(track) {
                rec_seg_item(
                  track,
                  fn() { "10 fps" },
                  fn() { rec_exp_gif_fps.get() == 10 },
                  fn() { rec_exp_gif_fps.set(10) },
                  done_dot=fn() { rec_has_exported_combo(2, 0, rec_exp_scale.get(), 10) },
                )
                rec_seg_item(
                  track,
                  fn() { "15 fps" },
                  fn() { rec_exp_gif_fps.get() == 15 },
                  fn() { rec_exp_gif_fps.set(15) },
                  done_dot=fn() { rec_has_exported_combo(2, 0, rec_exp_scale.get(), 15) },
                )
                rec_seg_item(
                  track,
                  fn() { "20 fps" },
                  fn() { rec_exp_gif_fps.get() == 20 },
                  fn() { rec_exp_gif_fps.set(20) },
                  done_dot=fn() { rec_has_exported_combo(2, 0, rec_exp_scale.get(), 20) },
                )
              })
            }, at_once=true)

            // Size row: 原始 | 1080p | 720p (+ 480p for GIF)
            rec_form_row(body, "尺寸", fn(track) {
              rec_seg_item(
                track,
                fn() { tr("原始") },
                fn() { rec_exp_scale.get() == 0 },
                fn() { rec_exp_scale.set(0) },
              )
              rec_seg_item(
                track,
                fn() { "1080p" },
                fn() { rec_exp_scale.get() == 1920 },
                fn() { rec_exp_scale.set(1920) },
                disabled=fn() { rec_scale_disabled(1920) },
              )
              rec_seg_item(
                track,
                fn() { "720p" },
                fn() { rec_exp_scale.get() == 1280 },
                fn() { rec_exp_scale.set(1280) },
                disabled=fn() { rec_scale_disabled(1280) },
              )
              track.show(fn() { rec_exp_fmt.get() == 2 }, fn(g480) {
                g480.row(Is(true)).grow(Is(1.0)) |> ignore
                rec_seg_item(
                  g480,
                  fn() { "480p" },
                  fn() { rec_exp_scale.get() == 854 },
                  fn() { rec_exp_scale.set(854) },
                  disabled=fn() { rec_scale_disabled(854) },
                )
              }, at_once=true)
            })

            // Footer divider + big size readout & actions
            body.box(fn(ln) { ln.height(Is(Some(1.0))).ground(Is(0xFFFFFF12L)) |> ignore }) |> ignore

            body.box(fn(foot) {
              foot.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))).padding(Is((0.0, 2.0, 0.0, 0.0))).shrink(Is(0.0))
              |> ignore

              // Left: prominent tabular size readout + quiet subtitle (or encoding progress / reveal link)
              foot.box(fn(st) {
                st.grow(Is(1.0)).gap(Is(2.0)).lines_up(Is(Some(Start))) |> ignore

                // Phase 4 (Ready): big estimated size + saved % / direct copy subtitle
                st.show(fn() { rec_phase.get() == 4 }, fn(rdy) {
                  rdy.gap(Is(2.0)).lines_up(Is(Some(Start))) |> ignore
                  rdy.box(fn(big) {
                    big
                    .shrink(Is(0.0))
                    .words(By(rec_current_est_str), look={
                      ..@view.words_plain,
                      size: 15.0,
                      weight: 700,
                      line: 18.0,
                      wrap: false,
                    })
                    .ink(Is(0xF5F6F8FFL))
                    |> ignore
                  })
                  |> ignore
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
                        look={ ..@view.words_plain, size: 10.5, weight: 500, line: 13.0, wrap: false },
                      )
                      .ink(Is(0x7D8492FFL))
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
                          weight: 600,
                          line: 13.0,
                          wrap: false,
                        })
                        .ink(Is(0x3DD68CFFL))
                        |> ignore
                      },
                      at_once=true,
                    )
                  })
                  |> ignore
                }, at_once=true)

                // Phase 5 (Encoding): percentage + slim progress bar
                st.show(fn() { rec_phase.get() == 5 }, fn(enc) {
                  enc.gap(Is(5.0)).lines_up(Is(Some(Start))) |> ignore
                  enc.box(fn(t) {
                    t
                    .shrink(Is(0.0))
                    .words(By(fn() { tr("正在编码 ") + rec_exp_pct.get().to_string() + "%" }), look={
                      ..@view.words_plain,
                      size: 12.5,
                      weight: 600,
                      line: 16.0,
                      wrap: false,
                    })
                    .ink(Is(0x88C8FFFFL))
                    |> ignore
                  })
                  |> ignore
                  enc.box(fn(bar_bg) {
                    bar_bg.width(Is(Some(124.0))).height(Is(Some(4.0))).radius(Is(2.0)).ground(Is(0xFFFFFF16L)).clips(Is(true))
                    |> ignore
                    bar_bg.box(fn(bar_fg) {
                      bar_fg
                      .height(Is(Some(4.0)))
                      .width(By(fn() { Some(dmax(4.0, 124.0 * rec_exp_pct.get().to_double() / 100.0)) }))
                      .radius(Is(2.0))
                      .ground(Is(0x0A84FFFFL))
                      |> ignore
                    })
                    |> ignore
                  })
                  |> ignore
                }, at_once=true)

                // Phase 6 (Already Exported / Saved): emerald actual size + inline Reveal link
                st.show(fn() { rec_phase.get() == 6 }, fn(done_v) {
                  done_v.gap(Is(2.0)).lines_up(Is(Some(Start))) |> ignore
                  done_v.box(fn(big) {
                    big
                    .shrink(Is(0.0))
                    .words(By(fn() { rec_fmt_size(rec_exp_bytes.get()) }), look={
                      ..@view.words_plain,
                      size: 15.0,
                      weight: 700,
                      line: 18.0,
                      wrap: false,
                    })
                    .ink(Is(0x3DD68CFFL))
                    |> ignore
                  })
                  |> ignore
                  done_v.box(fn(sub) {
                    sub.row(Is(true)).gap(Is(4.0)).lines_up(Is(Some(Middle))) |> ignore
                    sub.box(fn(t) {
                      t
                      .shrink(Is(0.0))
                      .words(
                        By(fn() { if rec_copied_note.get() { tr("已复制 · ") } else { tr("已导出 · ") } }),
                        look={ ..@view.words_plain, size: 10.5, weight: 500, line: 13.0, wrap: false },
                      )
                      .ink(Is(0x7D8492FFL))
                      |> ignore
                    })
                    |> ignore
                    sub.box(fn(op) {
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
                        .words(By(fn() { tr("打开位置") }), look={
                          ..@view.words_plain,
                          size: 10.5,
                          weight: 500,
                          line: 13.0,
                          wrap: false,
                        })
                        .ink(By(fn() { if op.pointed() { 0xFFFFFFFFL } else { 0xC4CAD6FFL } }))
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
                  err_v
                  .shrink(Is(0.0))
                  .words(By(fn() { rec_err.get() }), look={
                    ..@view.words_plain,
                    size: 11.5,
                    weight: 500,
                    line: 15.0,
                    wrap: false,
                  })
                  .ink(Is(0xF5A524FFL))
                  |> ignore
                }, at_once=true)
              })
              |> ignore

              // Right: Save As (ghost) + Save & Copy (Apple Blue) / Copy File (crisp white)
              foot.box(fn(btns) {
                btns.row(Is(true)).gap(Is(7.0)).shrink(Is(0.0)).lines_up(Is(Some(Middle))) |> ignore

                btns.box(fn(sa) {
                  sa
                  .height(Is(Some(32.0)))
                  .shrink(Is(0.0))
                  .padding(Is((11.0, 0.0, 11.0, 0.0)))
                  .radius(Is(8.5))
                  .lines_up(Is(Some(Middle)))
                  .lies_along(Is(Middle))
                  .presses(Is(true))
                  .cursor(By(fn() { if rec_phase.get() == 5 { None } else { Some(Hand) } }))
                  .says(By(fn() { Some(@view.said(Button, label=tr("另存为"))) }))
                  .on_press(fn() { if rec_phase.untracked() != 5 { rec_run_export(true) } })
                  .ground(By(fn() {
                    if rec_phase.get() == 5 {
                      0xFFFFFF0AL
                    } else if sa.pressed() {
                      0xFFFFFF26L
                    } else if sa.pointed() {
                      0xFFFFFF1CL
                    } else {
                      0xFFFFFF12L
                    }
                  }))
                  |> ignore
                  sa.box(fn(t) {
                    t
                    .shrink(Is(0.0))
                    .words(By(fn() { tr("另存为") }), look={
                      ..@view.words_plain,
                      size: 11.5,
                      weight: 600,
                      line: 15.0,
                      wrap: false,
                    })
                    .ink(By(fn() { if rec_phase.get() == 5 { 0xFFFFFF4DL } else { 0xD5D9E2FFL } }))
                    |> ignore
                  })
                  |> ignore
                })
                |> ignore

                btns.box(fn(pri) {
                  pri
                  .height(Is(Some(32.0)))
                  .shrink(Is(0.0))
                  .padding(Is((14.0, 0.0, 14.0, 0.0)))
                  .radius(Is(8.5))
                  .lines_up(Is(Some(Middle)))
                  .lies_along(Is(Middle))
                  .presses(Is(true))
                  .cursor(By(fn() { if rec_phase.get() == 5 { None } else { Some(Hand) } }))
                  .says(By(fn() {
                    Some(@view.said(Button, label=if rec_phase.get() == 6 { tr("复制文件") } else { tr("保存并复制") }))
                  }))
                  .on_press(fn() { if rec_phase.untracked() != 5 { rec_run_export(false) } })
                  .ground(By(fn() {
                    match rec_phase.get() {
                      5 => 0xFFFFFF14L
                      6 =>
                        if pri.pressed() {
                          0xDDE1E8FFL
                        } else if pri.pointed() {
                          0xFFFFFFFFL
                        } else {
                          0xF2F4F7FFL
                        }
                      _ =>
                        if pri.pressed() {
                          0x006CE0FFL
                        } else if pri.pointed() {
                          0x2292FFFFL
                        } else {
                          0x0A84FFFFL
                        }
                    }
                  }))
                  |> ignore
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
                      match rec_phase.get() {
                        5 => 0xFFFFFF59L
                        6 => 0x121316FFL
                        _ => 0xFFFFFFFFL
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
        })
        |> ignore
      }, at_once=true)
    })
    |> ignore
  })
  |> ignore
}
