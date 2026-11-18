// The words PinShot says, in Chinese or in English (the user, 2026-11-17: 「加上语言选择（中/英）」): written in
// Chinese where they are used, said through `tr`, which gives the English of them where English is in force (as the
// settings say: the system's language, else the one chosen). Read in a binding, a change of language redraws them.

///|
/// Whether English is in force (else Chinese).
let english : @signals.Signal[Bool] = @signals.signal(false)

///|
/// The languages offered: the system's (Chinese where Windows' own is Chinese, else English), Chinese, English.
let language_names : Array[String] = ["跟随系统", "中文", "English"]

///|
/// The language in force by the settings' choice (0 the system's, 1 Chinese, 2 English).
fn apply_language(choice : Int) -> Unit {
  english.set(
    match choice {
      1 => false
      2 => true
      _ => ps_ui_chinese() == 0
    },
  )
}

///|
/// `zh` in the language in force: its English where English is (itself where none is written).
fn tr(zh : String) -> String {
  if !english.get() {
    return zh
  }
  match en_words.get(zh) {
    Some(en) => en
    None => zh
  }
}

///|
let en_words : Map[String, String] = {
  // the bar
  "选择（V）": "Select (V)",
  "矩形": "Rectangle",
  "椭圆": "Ellipse",
  "箭头（按住 Shift 水平、垂直或 45°）": "Arrow (hold Shift: horizontal, vertical or 45°)",
  "直线（按住 Shift 水平、垂直或 45°）": "Line (hold Shift: horizontal, vertical or 45°)",
  "画笔": "Pen",
  "马赛克": "Mosaic",
  "聚焦（框出重点，其余变暗）": "Focus (keep a part bright, dim the rest)",
  "序号": "Number",
  "文字": "Text",
  "撤销 Ctrl+Z": "Undo Ctrl+Z",
  "重做 Ctrl+Y": "Redo Ctrl+Y",
  "贴到屏幕 Ctrl+T": "Pin to screen Ctrl+T",
  "保存 Ctrl+S": "Save Ctrl+S",
  "关闭 Esc": "Close Esc",
  "复制 Enter": "Copy Enter",
  "细": "Thin",
  "中": "Medium",
  "粗": "Thick",
  "输入文字": "Type here",
  // pins
  "剪贴板里没有图片": "No image on the clipboard",
  "复制": "Copy",
  "另存为…": "Save as…",
  "置顶": "Always on top",
  "移到最前": "Bring to front",
  "原始大小 (100%)": "Actual size (100%)",
  "不透明度": "Opacity",
  "关闭": "Close",
  "关闭全部贴图": "Close all pins",
  // the icon's menu and its note
  "截图": "Screenshot",
  "贴图剪贴板中的图片": "Pin clipboard image",
  "显示/隐藏全部贴图": "Show/hide all pins",
  "设置…": "Settings…",
  "打开截图文件夹": "Open screenshots folder",
  "退出 PinShot": "Quit PinShot",
  "截图快捷键被其他程序占用：": "Screenshot shortcut taken by another program: ",
  "点这里打开 PinShot 设置换一个；或者退出占用它的程序（比如 PixPin）后重新打开 PinShot。": "Click here to choose another in PinShot's settings, or quit the program holding it (PixPin, say) and open PinShot again.",
  // the settings
  "PinShot 设置": "PinShot Settings",
  "快捷键": "Shortcuts",
  "已被其他程序占用，换一个": "Taken by another program: choose another",
  "不用快捷键": "None",
  "贴图": "Pins",
  "打开时置顶": "Always on top when opened",
  "打开时的不透明度": "Opacity when opened",
  "保存": "Saving",
  "每次询问保存位置": "Ask where to save each time",
  "复制时也保存一份到文件夹": "Also save a copy to the folder when copying",
  "文件夹": "Folder",
  "打开": "Open",
  "通用": "General",
  "语言": "Language",
  "跟随系统": "System",
  "复制、保存、贴图时播放快门音效": "Play a shutter sound when copying, saving or pinning",
  "开机时启动 PinShot": "Start PinShot when Windows starts",
  "关于": "About",
  "版本": "Version",
  "免费、无广告，不联网、不收集任何数据。": "Free, no ads. Works offline and collects no data.",
  "免费、无广告，不收集任何数据；只在检查更新时联网。": "Free, no ads, collects no data. Goes online only to check for updates.",
  // updates
  "检查更新…": "Check for updates…",
  "检查更新": "Check for updates",
  "正在检查…": "Checking…",
  "前往下载": "Download",
  "立即更新": "Update now",
  "下载中 ": "Downloading ",
  "下载中…": "Downloading…",
  "重启并更新": "Restart to update",
  "正在更新…": "Updating…",
  "更新内容": "What's new",
  "已是最新版本": "You're up to date",
  "发现新版本 ": "New version available: ",
  "新版本 ": "Version ",
  " 已下载": " downloaded",
  "通过 Microsoft Store 更新": "Updated by the Microsoft Store",
  "自动更新": "Automatic updates",
  "每天检查一次，空闲时在后台下载并安装": "Checks daily; downloads and installs in the background when idle",
  "检查更新失败": "Couldn't check for updates",
  "下载更新失败": "Couldn't download the update",
  "检查更新失败，请检查网络": "Couldn't check for updates. Check your connection",
  "下载更新失败，请检查网络": "Couldn't download the update. Check your connection",
  "下载的文件校验失败": "The download failed its checksum",
  "无法写入程序所在的文件夹": "Can't write to PinShot's folder",
  "无法安装更新": "Couldn't install the update",
  "正在下载，请稍后再试": "A download is under way; try again shortly",
  "PinShot 已更新到 ": "PinShot updated to ",
  "点这里打开设置。": "Click here to open the settings.",
  "PinShot 有新版本：": "A new version of PinShot: ",
  "点这里打开设置更新。": "Click here to update in the settings.",
  "PinShot ": "PinShot ",
  "关闭全部贴图后会自动更新；也可以点这里在设置里立即更新。": "It installs once all pins are closed, or click here to update now in the settings.",
}
