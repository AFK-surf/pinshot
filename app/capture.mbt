// A capture: the screen frozen as the shortcut is pressed (the monitor the pointer is on, taken by the native side
// then), shown over it in the overlay (window 0, kept hidden between captures, made once as the run starts so a capture
// opens it at once), a part of it picked, marked up, and copied, saved or pinned. What is picked and drawn is kept in
// the screen's pixels of that monitor (whole pixels, its top left 0, 0); the overlay draws it at the monitor's scale.

///|
/// The monitor taken: where it is on the screen and how big (pixels), and its scale (pixels a point).
let mon : Ref[Rect] = Ref({ x: 0, y: 0, w: 0, h: 0 })

///|
let mon_scale : @signals.Signal[Double] = @signals.signal(1.0)

///|
/// The key the overlay shows the picture by ("" none): a new one each capture, so no decode of the last is shown.
let frozen_key : @signals.Signal[String] = @signals.signal("")

///|
let frozen_n : Ref[Int] = Ref(0)

///|
/// The windows on it, the front first (what a click picks while nothing is selected).
let windows_on : @signals.Signal[Array[Rect]] = @signals.signal_by([], same=fn(a, b) { physical_equal(a, b) })

///|
/// Whether a capture is open (the overlay up, or on its way up).
let capturing : @signals.Signal[Bool] = @signals.signal(false)

///|
/// Whether the overlay is seen (its first frame with the picture drawn).
let overlay_seen : @signals.Signal[Bool] = @signals.signal(false)

///|
/// When the shortcut was pressed (ps_now_ms), and how long the screen took to take: for the timings said in the log.
let asked_at : Ref[Double] = Ref(0.0)

///|
let took_ms : Ref[Double] = Ref(0.0)

///|
/// The pointer on the overlay, in the monitor's pixels (where it was last seen).
let pointer_px : @signals.Signal[(Double, Double)] = @signals.signal((0.0, 0.0))

///|
/// The part picked (None: none yet).
let sel : @signals.Signal[Rect?] = @signals.signal(None)

///|
/// What the hand does to the overlay now.
#derive(Eq)
enum Hand {
  /// nothing held
  Free
  /// a new part being dragged out from where it went down
  Drawing(Double, Double)
  /// the part moved, from where it went down and where it was then
  Moving(Double, Double, Rect)
  /// an edge or a corner of it held (-1 left/top, 1 right/bottom, 0 neither), from where it was then
  Sizing(Int, Int, Rect)
  /// a mark being drawn
  Marking
  /// a mark dragged from where it went down: the mark as it was, the marks as they were (it out of them while it is
  /// dragged, drawn as the draft), where it was among them, and by what: its handle (hx, hy: marks.mbt's
  /// mark_handles), or (-1, -1) the whole of it
  Dragging(Double, Double, Mark, Array[Mark], Int, Int, Int)
}

///|
let hand : @signals.Signal[Hand] = @signals.signal(Free)

///|
/// The window under the pointer while nothing is selected: what a click picks.
fn window_under() -> Rect? {
  if sel.get() is Some(_) {
    return None
  }
  let (x, y) = pointer_px.get()
  window_at(x, y)
}

///|
fn window_at(x : Double, y : Double) -> Rect? {
  let full : Rect = { x: 0, y: 0, w: mon.val.w, h: mon.val.h }
  let mut found : Rect? = None
  // (the front first; a part of a window, listed after it, wins over the window where it holds the pointer)
  let ws = windows_on.get()
  let mut i = 0
  while i < ws.length() {
    let r = ws[i]
    if r.contains(x, y) {
      found = r.within(full.w, full.h)
      // its parts after it: the smallest that holds the pointer
      let mut j = i + 1
      while j < ws.length() && inside(ws[j], r) {
        let c = ws[j]
        if c.contains(x, y) {
          match found {
            Some(f) if c.w * c.h < f.w * f.h => found = c.within(full.w, full.h)
            _ => ()
          }
        }
        j += 1
      }
      break
    }
    i += 1
  }
  match found {
    Some(_) => found
    None => Some(full)
  }
}

///|
fn inside(c : Rect, r : Rect) -> Bool {
  c.x >= r.x && c.y >= r.y && c.right() <= r.right() && c.bottom() <= r.bottom()
}

///|
/// The colour of the pixel at (`x`, `y`) of the picture taken: 0xRRGGBB, -1 where there is none (read where the
/// native side keeps it).
fn pixel_at(x : Int, y : Int) -> Int {
  ps_pixel(x, y)
}

///|
/// The windows' lines as rectangles.
fn parse_windows(s : String) -> Array[Rect] {
  let out : Array[Rect] = []
  for line in s.split("\n") {
    let n = match line.split(";").next() {
      Some(head) => numbers_of(head.to_owned())
      None => []
    }
    if n.length() == 4 {
      out.push({ x: n[0].to_int(), y: n[1].to_int(), w: n[2].to_int(), h: n[3].to_int() })
    }
  }
  out
}

///|
/// A capture begun as the shortcut is pressed (the native side taking the screen meanwhile): the overlay put up at the
/// monitor's size, out of sight, so its first frame there is drawn while the picture is taken.
fn prepare_capture(x : Int, y : Int, w : Int, h : Int, dpi : Double) -> Unit {
  let was = frozen_key.untracked()
  mon.val = { x, y, w, h }
  @signals.start_batch()
  mon_scale.set(dmax(1.0, dpi / 96.0))
  reset_marks()
  sel.set(None)
  hand.set(Free)
  tool.set(Move)
  words_open.set(None)
  let p = numbers_of(text_of(ps_pointer()))
  if p.length() == 2 {
    pointer_px.set((p[0] - x.to_double(), p[1] - y.to_double()))
  }
  frozen_key.set("")
  overlay_seen.set(false)
  capturing.set(true)
  @signals.end_batch()
  if was != "" {
    @ui.forget_image(was)
  }
  ps_capture_open(1)
  ps_cloak(0, 1)
  // (the keyboard taken but by the capture taken as the run starts: that one is never seen)
  ps_place(0, x, y, w, h, 1, if warming.val { 0 } else { 1 })
}

///|
/// The picture taken: shown in the overlay once it is a texture (overlay.mbt's reveal).
fn capture_taken() -> Unit {
  let info = numbers_of(text_of(ps_capture_info()))
  let bytes = ps_capture_take()
  if info.length() < 6 || bytes.length() == 0 {
    close_capture()
    return
  }
  took_ms.val = info[5]
  took_how.val = match text_of(ps_capture_info()).split(",").last() {
    Some(h) => h.to_owned()
    None => ""
  }
  taken_at.val = ps_now_ms()
  windows_on.set(parse_windows(text_of(ps_windows())))
  frozen_n.val += 1
  let key = "mem:frozen/\{frozen_n.val}"
  @ui.add_image(key, bytes)
  frozen_key.set(key)
}

///|
/// How the screen was taken ("gdi", "wgc start/frame/copy" ms).
let took_how : Ref[String] = Ref("")

///|
/// When the picture came over to the app.
let taken_at : Ref[Double] = Ref(0.0)

///|
/// The capture closed: the overlay gone at once, the picture let go of.
fn close_capture() -> Unit {
  if !capturing.untracked() {
    return
  }
  ps_capture_open(0)
  warming.val = false
  // (out of sight at once; made small and drawn once so, then hidden: what drew it at the monitor's size, 4K's
  // buffers and all, let go of while nothing is captured)
  ps_cloak(0, 1)
  ps_place(0, mon.val.x, mon.val.y, 16, 16, 0, 0)
  match overlay_root.val {
    Some(r) =>
      r.at_moment(r.cause_at() + 120.0, fn() {
        if !capturing.untracked() {
          ps_hide(0)
          ps_gpu_flush()
        }
      }, later=true)
      |> ignore
    None => ps_hide(0)
  }
  let key = frozen_key.untracked()
  @signals.start_batch()
  capturing.set(false)
  overlay_seen.set(false)
  sel.set(None)
  hand.set(Free)
  reset_marks()
  frozen_key.set("")
  @signals.end_batch()
  ps_capture_release()
  windows_on.set([])
  if key != "" {
    @ui.forget_image(key)
  }
  trim_soon()
}

///|
/// The memory the capture held given back to the system a moment after it closed (its decode let go by then).
fn trim_soon() -> Unit {
  match overlay_root.val {
    Some(r) => r.at_moment(now() + 300.0, fn() { ps_gpu_flush() }, later=true) |> ignore
    None => ps_gpu_flush()
  }
}
