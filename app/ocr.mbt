// The words in a part taken or in a pin, read by Windows' own OCR (ocr_win.cpp: offline, on a thread of its own) and
// shown in a small window of this run, over the pins: the words in a field to correct, a button to copy them. One
// window, the last picture asked for in it (a reading come back for an older one is let go).
//
// The language: the user (2026-11-19: 「我有可能同一台设备要中文要英文要日文要韩文」). By itself it is read with each of
// Chinese, English, Japanese and Korean that Windows has, and the reading that looks most like one kept (ocr_win.cpp);
// a language picked in the window reads it again in that one alone, and is kept for the next (the settings).

///|
/// The languages words are read in: Windows' tag, the name shown (each in its own language). The first: by itself.
let ocr_langs : Array[(String, String)] = [("", "自动"), ("zh", "中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어")]

///|
fn ocr_lang_named(tag : String) -> Int {
  for i, l in ocr_langs {
    if i > 0 && l.0 == tag {
      return i
    }
  }
  0
}

///|
/// The name of the language a reading was in ("zh-Hans-CN" 中文).
fn ocr_lang_shown(tag : String) -> String {
  for i, l in ocr_langs {
    if i > 0 && (tag == l.0 || tag.has_prefix(l.0 + "-")) {
      return l.1
    }
  }
  tag
}

///|
/// The picture in the window (read again in another language).
let ocr_png : Ref[Bytes] = Ref(Bytes::make(0, b'\x00'))

///|
let ocr_wid : Ref[Int] = Ref(0)

///|
/// The reading the window waits for (a reading told back with another is let go).
let ocr_id : Ref[Int] = Ref(0)

///|
/// Where the reading is: Reading, Read (its words in the field; the language they were read in), Failed (why).
#derive(Eq)
enum OcrState {
  Reading
  Read(String)
  Failed(String)
}

///|
let ocr_state : @signals.Signal[OcrState] = @signals.signal(Reading)

///|
let ocr_field : @ui.Field = @ui.Field::new()

///|
/// The words in `png` read, the window opened (or brought in front) to show them as they come.
fn read_words(png : Bytes) -> Unit {
  ocr_png.val = png
  ocr_id.val += 1
  ocr_field.set("")
  ocr_state.set(Reading)
  if ocr_wid.val <= 0 || !@ui.window_front_here(ocr_wid.val) {
    let wid = @ui.window_open_here("ocr")
    if wid <= 0 {
      log("ocr: no window")
      return
    }
    ocr_wid.val = wid
    ps_center(wid, 480, 420)
  }
  // (over the pins, which are over the others)
  ps_topmost(ocr_wid.val, 1, 1)
  read_again()
}

///|
/// The picture in the window read (again) in the language picked.
fn read_again() -> Unit {
  let want = ocr_langs[settings.untracked().ocr_lang].0
  if ps_ocr(ocr_id.val, ocr_png.val, @utf8.encode(want)) == 0 {
    ocr_state.set(Failed("failed"))
  }
}

///|
fn ocr_pick(i : Int) -> Unit {
  if i == settings.untracked().ocr_lang {
    return
  }
  change_settings(fn(s) { { ..s, ocr_lang: i } })
  if ocr_png.val.length() > 0 {
    ocr_id.val += 1
    ocr_field.set("")
    ocr_state.set(Reading)
    read_again()
  }
}

///|
/// A reading told back ({"do":"ocr","id":N,"why":"","lang":"zh-Hans-CN","lines":3,"ms":120}, its words beside).
fn ocr_told(o : Map[String, Json], words : Bytes?) -> Unit {
  let id = match o.get("id") {
    Some(Number(v, ..)) => v.to_int()
    _ => -1
  }
  let str = fn(k : String) {
    match o.get(k) {
      Some(String(s)) => s
      _ => ""
    }
  }
  let text = match words {
    Some(b) => text_of(b)
    None => ""
  }
  log("ocr \{id}: why '\{str("why")}', \{str("lang")}, \{text.length()} chars")
  if id != ocr_id.val || ocr_wid.val <= 0 {
    return
  }
  if str("why") != "" {
    ocr_state.set(Failed(str("why")))
  } else if text.trim() == "" {
    ocr_state.set(Failed("none"))
  } else {
    ocr_field.set(text, caret=0)
    ocr_state.set(Read(str("lang")))
  }
}

///|
/// The part picked (with its marks) read.
fn ocr_out() -> Unit {
  if exporting.val != "" || sel.untracked() is None {
    return
  }
  exporting.val = "ocr"
  ps_cloak(0, 1)
  picture_of_part(fn(png) {
    exporting.val = ""
    close_capture()
    match png {
      Some(png) => read_words(png)
      None => ()
    }
  })
}

///|
fn ocr_close() -> Unit {
  if ocr_wid.val > 0 {
    close_window(ocr_wid.val)
  }
}

///|
fn ocr_copy() -> Unit {
  let t = ocr_field.text()
  if t == "" {
    return
  }
  @hostapi.clipboard_set(t)
  toast(tr("已复制"))
  ocr_close()
}

///|
fn ocr_failed_words(why : String) -> String {
  match why {
    "none" => tr("没有识别到文字")
    "missing" => tr("这台电脑没装这种语言的文字识别。到 设置 › 时间和语言 › 语言和区域 添加这种语言后再试。")
    "no-language" | "no-ocr" =>
      tr("Windows 里没有可用的文字识别语言。到 设置 › 时间和语言 › 语言和区域 添加中文或英文后再试。")
    _ => tr("识别失败")
  }
}

///|
fn ocr_window(root : @view.View) -> Unit {
  root.tree.hand_over_presses(false)
  root.keymap(Is(@view.Keymap::new([{ keys: [{ code: @ui.key_escape, mods: 0 }], action: "close", when: Always }])))
  |> ignore
  root.on_action("close", fn(_) {
    ocr_close()
    true
  })
  |> ignore
  root.box(fn(page) {
    page.over(Is(true)).ground(Is(set_ground)).padding(Is((20.0, 16.0, 20.0, 16.0))).gap(Is(12.0)) |> ignore
    page.box(fn(head) {
      head.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
      head.box(fn(t) {
        t.grow(Is(1.0)) |> ignore
        set_words(t, fn() { tr("提取的文字") }, 15.0, set_ink, weight=600)
      })
      |> ignore
      choice(head, ocr_langs.map(fn(l) { l.1 }), fn() { settings.get().ocr_lang }, ocr_pick)
    })
    |> ignore
    page.box(fn(card) {
      card
      .grow(Is(1.0))
      .min_height(Is(Some(0.0)))
      .ground(Is(set_card))
      .radius(Is(8.0))
      .edge(Is((1.0, 0xFFFFFF14L)))
      .padding(Is((12.0, 10.0, 12.0, 10.0)))
      |> ignore
      card.box(fn(msg) {
        msg
        .over(Is(true))
        .padding(Is((12.0, 10.0, 12.0, 10.0)))
        .laid_nowhere(By(fn() { ocr_state.get() is Read(_) }))
        |> ignore
        msg.box(fn(w) {
          w
          .words(By(fn() {
            match ocr_state.get() {
              Reading => tr("正在识别…")
              Failed(why) => ocr_failed_words(why)
              Read(_) => ""
            }
          }), look={ ..@view.words_plain, size: 13.0, weight: 400, line: 19.0, wrap: true })
          .ink(Is(set_muted))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      card.box(fn(f) {
        f.laid_nowhere(By(fn() { !(ocr_state.get() is Read(_)) })) |> ignore
        @ui.field(
          f,
          ocr_field,
          font_size=13.0,
          line=19.0,
          min_lines=1,
          max_lines=14,
          color=set_ink,
          placeholder_color=set_muted,
          caret_color=0x2F9BFFFFL,
          enter_sends=false,
          label=tr("提取的文字"),
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
    page.box(fn(foot) {
      foot.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
      foot.box(fn(s) {
        s.grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        set_words(s, fn() {
          match ocr_state.get() {
            Read(lang) => tr("识别为") + " " + ocr_lang_shown(lang)
            _ => ""
          }
        }, 11.5, set_muted)
      })
      |> ignore
      small_button(foot, "关闭", ocr_close)
      small_button(foot, "复制", ocr_copy)
    })
    |> ignore
  })
  |> ignore
}
