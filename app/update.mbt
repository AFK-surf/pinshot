// Updates, as desktop apps do them (the user, 2026-11-19: 「加一个检查更新的按钮和自动更新的开关，按照业内标准去做」):
//
// - What the latest release is: https://pin-shot.pages.dev/dl/latest.json (packaging/publish.ps1 puts it there with
//   each release): {"version":"1.0.3","setup":<bytes>,"exe":<bytes>,"setup_sha256":"…","exe_sha256":"…"}. The files
//   are those of that version's own folder (/dl/v<version>/…, never changed once put there).
// - 设置 › 关于: 检查更新 asks now and says what it found; a newer version is installed by 立即更新 (downloaded, its
//   SHA-256 checked, put in place, PinShot started again).
// - 自动更新 (off unless turned on: the user, 2026-11-19, 「自动更新默认关掉」): asked a minute after PinShot starts and then once a day; a newer version is
//   downloaded in the background and put in place once nobody is using PinShot (no capture, no pin, the settings
//   closed, two minutes with no keyboard or mouse), so a pin is never closed under the person by an update. Turned off,
//   PinShot goes online only when 检查更新 is pressed.
// - Put in place by how it was installed: PinShot-Setup's copy by the new installer run silently (it keeps the choices
//   made as it was installed and starts PinShot again); the portable exe swapped for the new one beside it; a Store
//   package not at all (the Store updates it: the settings say so, and nothing here goes online).
// - The new run says it was updated (a note from the icon).

///|
let latest_url : String = "https://pin-shot.pages.dev/dl/latest.json"

///|
let download_base : String = "https://pin-shot.pages.dev/dl/"

///|
/// The download page (where a version that cannot be put in place here is got by hand).
let site_url : String = "https://pin-shot.pages.dev"

///|
/// What is known of updates now, as the settings show it.
#derive(Eq)
enum Update {
  /// nothing asked yet this run
  Unasked
  Checking
  /// this version is the latest
  Latest
  /// a newer version, not downloaded (where it cannot be put in place here: `by_hand`, the download page)
  Found(String, Bool)
  /// downloading it: the percent done (-1 not known)
  Fetching(String, Int)
  /// downloaded and checked, to be put in place
  Ready(String)
  Installing
  /// what went wrong, in Chinese (said through `tr`)
  Failed(String)
}

///|
let update : @signals.Signal[Update] = @signals.signal(Unasked)

///|
/// The latest release as latest.json said it.
#derive(Eq)
struct Release {
  version : String
  setup_sha : String
  exe_sha : String
}

///|
let release : Ref[Release?] = Ref(None)

///|
/// Where the release was downloaded to.
let update_file : Ref[String] = Ref("")

///|
/// Whether the person asked for this (检查更新, 立即更新): what is found is put in place at once, not waited for.
let update_asked : Ref[Bool] = Ref(false)

///|
/// When the release downloaded came to be ready (seconds since 1970), and whether the person was told it waits.
let ready_at : Ref[Double] = Ref(0.0)

///|
let ready_noted : Ref[Bool] = Ref(false)

///|
/// How this copy was installed (ps_install_kind: 2 the Store's, 1 PinShot-Setup's, 0 the portable exe).
let install_kind : Ref[Int] = Ref(-1)

///|
fn update_kind() -> Int {
  if install_kind.val < 0 {
    install_kind.val = ps_install_kind()
  }
  install_kind.val
}

///|
/// Whether this copy updates itself (the Store's is updated by the Store).
fn updates_here() -> Bool {
  update_kind() != 2
}

///|
let day_s : Double = 86400.0

///|
fn update_state_path() -> String {
  text_of(ps_data_dir()) + "\\update.json"
}

///|
/// When updates were last asked for (seconds since 1970; 0 never), kept across runs in update.json.
fn last_checked() -> Double {
  match json_of(text_of(ps_read_file(cstr(update_state_path())))) {
    Some(Json::Object(o)) =>
      match o.get("checked") {
        Some(Number(v, ..)) => v
        _ => 0.0
      }
    _ => 0.0
  }
}

///|
fn set_last_checked(at : Double) -> Unit {
  let o : Map[String, Json] = Map([])
  o["checked"] = Json::number(at.floor())
  ps_write_file(cstr(update_state_path()), @utf8.encode(Json::object(o).stringify())) |> ignore
}

///|
/// A version's numbers ("1.0.10" → [1, 0, 10]; what is not a number counts 0).
fn version_parts(v : String) -> Array[Int] {
  v.trim().split(".").map(fn(p) { @string.parse_int(p.to_string()) catch { _ => 0 } }).collect()
}

///|
/// Whether version `a` is newer than `b`.
fn newer(a : String, b : String) -> Bool {
  let x = version_parts(a)
  let y = version_parts(b)
  let n = if x.length() > y.length() { x.length() } else { y.length() }
  for i in 0..<n {
    let p = if i < x.length() { x[i] } else { 0 }
    let q = if i < y.length() { y[i] } else { 0 }
    if p != q {
      return p > q
    }
  }
  false
}

///|
fn agent() -> Bytes {
  cstr("PinShot/" + app_version + " (Windows)")
}

///|
fn update_busy() -> Bool {
  match update.untracked() {
    Checking | Fetching(_, _) | Installing => true
    _ => false
  }
}

///|
/// As PinShot starts: what an earlier update left removed, the ticks begun (a minute after the start, then every ten
/// minutes: each asks again where a day has gone by since the last time, and puts a downloaded release in place once
/// nobody uses PinShot), and the person told where this run is the update.
fn start_updates(updated : Bool) -> Unit {
  if !updates_here() {
    return
  }
  ps_update_cleanup()
  if updated {
    log("update: now \{app_version}")
    ps_tray_note(cstr(tr("PinShot 已更新到 ") + app_version), cstr(tr("点这里打开设置。")))
  }
  ps_update_ticks(60 * 1000, 10 * 60 * 1000)
}

///|
/// The tick: asked again where it is due, a release downloaded put in place where nobody uses PinShot.
fn update_tick() -> Unit {
  if !settings.untracked().auto_update || update_busy() {
    return
  }
  match update.untracked() {
    Ready(_) => install_when_idle()
    _ => {
      let now = ps_epoch_s()
      let last = last_checked()
      // (a day after the last time; an hour after one that failed; a clock set back counts as due too)
      let wait = if update.untracked() is Failed(_) { 3600.0 } else { day_s }
      if now - last >= wait || last > now + 60.0 {
        check_update(false)
      }
    }
  }
}

///|
/// The latest release asked for: by the person (`asked`: what is found waits for 立即更新) or by the tick (what is
/// found is downloaded).
fn check_update(asked : Bool) -> Unit {
  if !updates_here() || update_busy() {
    return
  }
  // (a release downloaded already is not asked for again: 重启并更新 puts it in place)
  if update.untracked() is Ready(_) {
    return
  }
  update_asked.val = asked
  if ps_fetch(cstr(latest_url), cstr(""), cstr(""), agent()) == 1 {
    update.set(Checking)
  } else {
    update.set(Failed("正在下载，请稍后再试"))
  }
}

///|
/// What a fetch told: latest.json read, a download's progress, a download done or failed.
fn update_told(what : String, o : Map[String, Json], body : Bytes?) -> Unit {
  let ok = o.get("ok") is Some(True)
  match what {
    "fetching" => {
      guard update.untracked() is Fetching(v, _) else { return }
      let n = fn(k : String) {
        match o.get(k) {
          Some(Number(x, ..)) => x
          _ => 0.0
        }
      }
      let total = n("total")
      let pct = if total > 0.0 { (n("got") * 100.0 / total).to_int() } else { -1 }
      update.set(Fetching(v, pct))
    }
    "fetched" =>
      match update.untracked() {
        Checking => if ok { latest_read(body) } else { fetch_failed(o, "检查更新失败") }
        Fetching(v, _) =>
          if ok {
            log("update: \{v} downloaded")
            ready_at.val = ps_epoch_s()
            ready_noted.val = false
            update.set(Ready(v))
            if update_asked.val {
              install_update()
            } else {
              install_when_idle()
            }
          } else {
            fetch_failed(o, "下载更新失败")
          }
        _ => ()
      }
    _ => ()
  }
}

///|
fn fetch_failed(o : Map[String, Json], head : String) -> Unit {
  let why = match o.get("error") {
    Some(String(s)) => s
    _ => ""
  }
  log("update: \{head}: \{why}")
  update.set(
    Failed(
      match why {
        "checksum" => "下载的文件校验失败"
        "cannot write" => "无法写入程序所在的文件夹"
        s if s.has_prefix("http ") => head
        _ => head + "，请检查网络"
      },
    ),
  )
}

///|
/// latest.json read: this version the latest, or a newer one found (downloaded at once where the tick asked).
fn latest_read(body : Bytes?) -> Unit {
  let text = match body {
    Some(b) => text_of(b)
    None => ""
  }
  guard json_of(text) is Some(Json::Object(o)) else {
    update.set(Failed("检查更新失败"))
    return
  }
  let s = fn(k : String) {
    match o.get(k) {
      Some(String(v)) => v.trim().to_string().to_lower()
      _ => ""
    }
  }
  let version = s("version")
  if version == "" {
    update.set(Failed("检查更新失败"))
    return
  }
  set_last_checked(ps_epoch_s())
  if !newer(version, app_version) {
    log("update: \{app_version} is the latest")
    update.set(Latest)
    return
  }
  let r = { version, setup_sha: s("setup_sha256"), exe_sha: s("exe_sha256") }
  release.val = Some(r)
  // (a release that names no SHA-256 for the file this copy needs is not put in place unchecked: got by hand)
  let sha = if update_kind() == 1 { r.setup_sha } else { r.exe_sha }
  let by_hand = sha.length() != 64
  log("update: \{version} found\{if by_hand { " (no checksum: by hand)" } else { "" }}")
  update.set(Found(version, by_hand))
  if !update_asked.val {
    if by_hand {
      ps_tray_note(cstr(tr("PinShot 有新版本：") + version), cstr(tr("点这里打开设置更新。")))
    } else {
      download_update()
    }
  }
}

///|
/// The release found downloaded (the installer, or the portable exe), checked as it comes.
fn download_update() -> Unit {
  guard release.val is Some(r) else { return }
  let (url, name, sha) = if update_kind() == 1 {
    let name = "PinShot-Setup-\{r.version}.exe"
    (download_base + "v\{r.version}/" + name, name, r.setup_sha)
  } else {
    (download_base + "v\{r.version}/pinshot.exe", "pinshot.exe", r.exe_sha)
  }
  let path = text_of(ps_update_path(cstr(name)))
  update_file.val = path
  if ps_fetch(cstr(url), cstr(path), cstr(sha), agent()) == 1 {
    log("update: downloading \{url}")
    update.set(Fetching(r.version, -1))
  } else {
    update.set(Failed("下载更新失败"))
  }
}

///|
/// The release downloaded put in place now (PinShot starts again in the new version).
fn install_update() -> Unit {
  guard update.untracked() is Ready(v) else { return }
  log("update: installing \{v}")
  update.set(Installing)
  let ok = if update_kind() == 1 {
    // (the installer quits this run itself: pinshot.exe --quit)
    ps_run_setup(cstr(update_file.val)) == 1
  } else {
    ps_swap_exe(cstr(update_file.val)) == 1
  }
  if !ok {
    log("update: could not install \{v}")
    update.set(Failed("无法安装更新"))
  }
}

///|
/// The release downloaded put in place if nobody uses PinShot now (no capture, no pin, the settings closed, nothing
/// touched for two minutes); else at a later tick. Waiting a day, the person is told once that it waits for them.
fn install_when_idle() -> Unit {
  guard update.untracked() is Ready(v) else { return }
  if !capturing.untracked() && pins.length() == 0 && settings_wid.val == 0 && ps_idle_ms() >= 120 * 1000 {
    install_update()
    return
  }
  if !ready_noted.val && ps_epoch_s() - ready_at.val >= day_s {
    ready_noted.val = true
    ps_tray_note(
      cstr(tr("PinShot ") + v + tr(" 已下载")),
      cstr(tr("关闭全部贴图后会自动更新；也可以点这里在设置里立即更新。")),
    )
  }
}

///|
/// The settings' button: what it says now.
fn update_button_words() -> String {
  match update.get() {
    Unasked | Latest | Failed(_) => tr("检查更新")
    Checking => tr("正在检查…")
    Found(_, true) => tr("前往下载")
    Found(_, false) => tr("立即更新")
    Fetching(_, p) => if p >= 0 { tr("下载中 ") + p.to_string() + "%" } else { tr("下载中…") }
    Ready(_) => tr("重启并更新")
    Installing => tr("正在更新…")
  }
}

///|
/// The settings' button pressed.
fn update_button_pressed() -> Unit {
  match update.untracked() {
    Unasked | Latest | Failed(_) => check_update(true)
    Found(_, true) => ps_open_url(cstr(site_url))
    Found(_, false) => {
      update_asked.val = true
      download_update()
    }
    Fetching(_, _) => update_asked.val = true
    Ready(_) => install_update()
    Checking | Installing => ()
  }
}

///|
/// What the settings say under 版本: what was found ("" nothing to say).
fn update_note() -> String {
  match update.get() {
    Unasked | Checking | Installing => ""
    Latest => tr("已是最新版本")
    Found(v, _) | Fetching(v, _) => tr("发现新版本 ") + v
    Ready(v) => tr("新版本 ") + v + tr(" 已下载")
    Failed(why) => tr(why)
  }
}

///|
/// The release notes of the version found.
fn update_notes_url() -> String {
  match release.val {
    Some(r) => "https://github.com/motion-space/pinshot/releases/tag/v" + r.version
    None => site_url
  }
}
