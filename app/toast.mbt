// A short word by the pointer that goes by itself (the user, 2026-11-17: 「假如没有可以pin的截图，需要有个轻微提示」): a small
// window of this run under the pointer, over the others, the keyboard left where it was, gone after a moment.

///|
let toast_wid : Ref[Int] = Ref(0)

///|
let toast_text : @signals.Signal[String] = @signals.signal("")

///|
/// A repeated message extends the lifetime of the existing window.
let toast_generation : @signals.Signal[Int] = @signals.signal(0)

///|
let toast_pad_x : Double = 18.0

///|
let toast_pad_t : Double = 12.0

///|
let toast_pad_b : Double = 22.0

///|
let toast_pill_h : Double = 34.0

///|
let toast_w : Double = 340.0

///|
let toast_h : Double = toast_pill_h + toast_pad_t + toast_pad_b

///|
/// `text` said by the pointer for a moment.
fn toast(text : String) -> Unit {
  toast_text.set(text)
  toast_generation.set(toast_generation.untracked() + 1)
  if toast_wid.val == 0 {
    ps_next_win_clear()
    let wid = @ui.window_open_here("toast")
    if wid <= 0 {
      log("toast: no window")
      return
    }
    toast_wid.val = wid
    ps_own(wid, 1) |> ignore
  }
  ps_toast_place(toast_wid.val, toast_w.to_int(), toast_h.to_int())
  log("toast \{toast_wid.val}: \{text}")
}

///|
fn toast_window(root : @view.View) -> Unit {
  root.reacts(fn() { toast_generation.get() }, fn(generation) {
    root.at_moment(root.cause_at() + 1600.0, fn() {
      if toast_wid.val != 0 && generation == toast_generation.untracked() {
        let wid = toast_wid.val
        toast_wid.val = 0
        close_window(wid)
      }
    }, later=true) |> ignore
  })
  root.presses(Is(false)) |> ignore
  // Transparent DirectComposition window carrying an mbui superellipse pill + soft shadow (zero DWM grey border).
  root.box(fn(g) {
    g
    .over(Is(true))
    .padding(Is((toast_pad_x, toast_pad_t, toast_pad_x, toast_pad_b)))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Start))
    |> ignore
    g.box(fn(pill) {
      pill
      .height(Is(Some(toast_pill_h)))
      .padding(Is((16.0, 0.0, 16.0, 0.0)))
      .radius(Is(11.0))
      .ground(Is(0x1E2026F2L))
      .edge(Is((1.0, 0xFFFFFF22L)))
      .shadow(Is((16.0, 5.0, 0x00000072L)))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      |> ignore
      pill.box(fn(t) {
        t
        .words(By(fn() { toast_text.get() }), look={ ..@view.words_plain, size: 13.0, weight: 500, line: 18.0, wrap: false })
        .ink(Is(0xF3F5F8FFL))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}
