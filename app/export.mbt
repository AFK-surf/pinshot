// The part picked, with its marks, as a picture of its own pixels (the monitor's: a 4K screen's part is copied at 4K):
// drawn by the GPU as the overlay draws it (mbui's take_picture: the same nodes, the picture and each mark, at the
// monitor's scale), read back as a PNG. Then copied, saved or pinned; the overlay is out of sight at once, closed once
// the picture is taken.

///|
/// What is being done with the picture, while it is taken ("" nothing): no second copy meanwhile.
let exporting : Ref[String] = Ref("")

///|
/// The part picked drawn as a picture of its own pixels, `done` told its PNG.
fn picture_of_part(done : (Bytes?) -> Unit) -> Unit {
  guard sel.untracked() is Some(r) else { return }
  if words_open.untracked() is Some(_) {
    commit_words()
  }
  let k = mon_scale.untracked()
  let key = frozen_key.untracked()
  let px = dmax(mon.val.w.to_double(), mon.val.h.to_double()).to_int()
  let w = r.w.to_double() / k
  let h = r.h.to_double() / k
  let (mw, mh) = (mon.val.w.to_double() / k, mon.val.h.to_double() / k)
  @ui.take_picture("part", w, fn(b) {
    b.height(Is(Some(h))).clips(Is(true)).lines_up(Is(Some(Start))) |> ignore
    b.box(fn(s) {
      s
      .width(Is(Some(mw)))
      .height(Is(Some(mh)))
      .shrink(Is(0.0))
      .offset(Is((-r.x.to_double() / k, -r.y.to_double() / k)))
      |> ignore
      s.box(fn(p) { p.over(Is(true)).image(Is(Some((key, "", px)))) |> ignore }) |> ignore
      marks_layer(s, editing=false)
    })
    |> ignore
  }, done, scale=k)
}

///|
/// The part copied (as a picture other programs paste: PNG and a bitmap), and kept in the pictures' folder where the
/// settings say so.
fn copy_out() -> Unit {
  if exporting.val != "" || sel.untracked() is None {
    return
  }
  exporting.val = "copy"
  shutter()
  let t0 = ps_now_ms()
  match sel.untracked() {
    Some(r) => {
      r_w.val = r.w
      r_h.val = r.h
    }
    None => ()
  }
  ps_cloak(0, 1)
  picture_of_part(fn(png) {
    exporting.val = ""
    match png {
      Some(png) => {
        // (a test run copies into a file, never onto the person's clipboard)
        let test_to = @ui.env("PINSHOT_TEST_COPY")
        if test_to != "" {
          ps_write_file(cstr(test_to), png) |> ignore
        } else {
          @hostapi.clipboard_set_image(png)
        }
        log("copy \{r_w.val}x\{r_h.val}: \{png.length()} bytes in \{num(ps_now_ms() - t0)} ms")
        if settings.untracked().keep_copies {
          let dir = settings.untracked().save_dir
          write_picture_file(dir + "\\" + file_name(), png)
        }
      }
      None => ()
    }
    close_capture()
  })
}

///|
fn file_name() -> String {
  let ext = if settings.untracked().save_format == 0 { ".png" } else { ".jpg" }
  "PinShot_" + text_of(ps_stamp()) + ext
}

///|
/// A picture (`png`) written to `path`: as JPEG (quality 92 or 80 per settings) when `path` ends in `.jpg`/`.jpeg`,
/// else lossless PNG.
fn write_picture_file(path : String, png : Bytes) -> Unit {
  let lower = path.to_lower()
  if lower.has_suffix(".jpg") || lower.has_suffix(".jpeg") {
    match picture_rgba(png) {
      Some((w, h, px)) => {
        let q = if settings.untracked().save_format == 2 { 80 } else { 92 }
        ps_write_file(cstr(path), @pixels.jpeg(w, h, px, quality=q)) |> ignore
        trim_soon()
        return
      }
      None => ()
    }
  }
  ps_write_file(cstr(path), png) |> ignore
}

///|
/// The part saved: where the settings say to ask, the system's dialog in the pictures' folder; else there at once.
fn save_out() -> Unit {
  if exporting.val != "" || sel.untracked() is None {
    return
  }
  exporting.val = "save"
  ps_cloak(0, 1)
  picture_of_part(fn(png) {
    exporting.val = ""
    match png {
      Some(png) => {
        let s = settings.untracked()
        // (the overlay hidden while the system's dialog is up: a dialog is not seen over a cloaked owner)
        let path = if s.ask_where {
          ps_hide(0)
          text_of(ps_save_dialog(-1, cstr(s.save_dir), cstr(file_name())))
        } else {
          s.save_dir + "\\" + file_name()
        }
        if path != "" {
          write_picture_file(path, png)
          shutter()
          log("saved \{path}")
          close_capture()
        } else {
          // (the dialog called off: back to the capture as it was)
          let m = mon.val
          ps_place(0, m.x, m.y, m.w, m.h, 1, 1)
          ps_cloak(0, 0)
        }
      }
      None => close_capture()
    }
  })
}

///|
/// The part pinned where it is on the screen.
fn pin_out() -> Unit {
  if exporting.val != "" {
    return
  }
  guard sel.untracked() is Some(r) else { return }
  exporting.val = "pin"
  shutter()
  ps_cloak(0, 1)
  let m = mon.val
  picture_of_part(fn(png) {
    exporting.val = ""
    match png {
      Some(png) => open_pin(png, m.x + r.x, m.y + r.y, r.w, r.h)
      None => ()
    }
    close_capture()
  })
}

///|
let r_w : Ref[Int] = Ref(0)

///|
let r_h : Ref[Int] = Ref(0)

///|
/// The shutter's sound, where the settings have it.
fn shutter() -> Unit {
  if settings.untracked().sound {
    ps_shutter()
  }
}
