// macOS releases are distributed as app bundles. The Windows installer update flow is omitted.
fn updates_here() -> Bool { false }

///|
/// The download page (and the sponsor page under it, settings.mbt).
let site_url : String = "https://pin-shot.pages.dev"

///|
/// A web page opened in the person's browser (https only; platform_mac.m).
#borrow(url)
extern "C" fn ps_open_url(url : Bytes) -> Unit = "ps_open_url"

///|
fn start_updates(_updated : Bool) -> Unit { () }

///|
fn update_tick() -> Unit { () }

///|
fn check_update(_asked : Bool) -> Unit { () }

///|
fn update_told(_what : String, _event : Map[String, Json], _body : Bytes?) -> Unit { () }

///|
fn update_settings(g : @view.View) -> Unit {
  set_row(g, "版本", fn(r) {
    set_words(r, fn() { "PinShot " + app_version }, 13.0, set_muted)
  })
}
