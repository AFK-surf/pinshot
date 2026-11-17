// Words written on the picture: a click with the words tool opens a line to type in where it was clicked (in the colour
// and size chosen); a click elsewhere, Escape or another tool puts what was typed down as a mark (nothing typed: none).

///|
/// Where the words being written start (pixels), None while none are.
let words_open : @signals.Signal[(Double, Double)?] = @signals.signal(None)

///|
let words_field : @ui.Field = @ui.Field::new()

///|
/// What is typed, as it is typed (how wide its line is drawn).
let words_typed : @signals.Signal[String] = @signals.signal("")

///|
fn open_words(x : Double, y : Double) -> Unit {
  words_field.set("")
  words_typed.set("")
  let size = words_pt(size_now.untracked()) * mon_scale.untracked()
  // (the line's middle where it was clicked)
  words_open.set(Some((x, y - size * 0.65)))
}

///|
fn commit_words() -> Unit {
  match words_open.untracked() {
    Some(at) => {
      let text = words_field.text().trim().to_owned()
      words_open.set(None)
      if text != "" {
        let m = new_mark(Words, [at])
        add_mark({ ..m, words: text })
      }
    }
    None => ()
  }
}

///|
/// The line typed in, while words are written.
fn words_editor(layer : @view.View) -> Unit {
  layer.show(fn() { words_open.get() is Some(_) }, fn(b) {
    b.over(Is(true)).presses(Is(true)).lines_up(Is(Some(Start))) |> ignore
    b.box(fn(f) {
      let k = @signals.untracked(fn() { mon_scale.get() })
      f
      .offset(By(fn() {
        match words_open.get() {
          Some((x, y)) => (x / k - 3.0, y / k - 2.0)
          None => (0.0, 0.0)
        }
      }))
      .width(By(fn() {
        // (as wide as what is typed, and room for what comes next)
        let size = words_pt(size_now.get())
        let longest = words_typed.get().split("\n").fold(init=0, fn(m, l) { if l.length() > m { l.length() } else { m } })
        Some(dmax(120.0, longest.to_double() * size * 1.05 + size * 2.0))
      }))
      .padding(Is((4.0, 2.0, 4.0, 2.0)))
      .ground(Is(0x0000004DL))
      .edge(Is((1.0, 0xFFFFFFB3L)))
      .radius(Is(3.0))
      |> ignore
      let size = @signals.untracked(fn() { words_pt(size_now.get()) })
      let color = @signals.untracked(fn() { color_now.get() })
      let node = @ui.field(
        f,
        words_field,
        placeholder=tr("输入文字"),
        font_size=size,
        line=(size * 1.3).round(),
        max_lines=12,
        color~,
        placeholder_color=0xFFFFFF99L,
        caret_color=color,
        enter_sends=false,
        edited=fn(t) { words_typed.set(t) },
      )
      ignore(node)
      words_field.focus()
    })
    |> ignore
  }, at_once=true)
}
