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
let toast_w : Double = 200.0

///|
let toast_h : Double = 36.0

///|
/// `text` said by the pointer for a moment.
fn toast(text : String) -> Unit {
  toast_text.set(text)
  toast_generation.set(toast_generation.untracked() + 1)
  if toast_wid.val == 0 {
    let wid = @ui.window_open_here("toast")
    if wid <= 0 {
      log("toast: no window")
      return
    }
    toast_wid.val = wid
    ps_own(wid, 1) |> ignore
    ps_shadow(wid)
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
  // (the window's own ground is not drawn: a layer over all of it, the words in its middle)
  root.box(fn(g) {
    g.over(Is(true)).ground(Is(0x26282DFFL)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
    g.box(fn(t) {
      t
      .words(By(fn() { toast_text.get() }), look={ ..@view.words_plain, size: 13.0, weight: 500, line: 18.0, wrap: false })
      .ink(Is(0xECEEF2FFL))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}
