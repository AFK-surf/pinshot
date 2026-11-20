# PinShot

[中文](#中文) · [Download](https://pin-shot.pages.dev)

Screenshot, mark up and pin to the screen, PixPin-style, for Windows and macOS. Written in MoonBit with still.fail's
[mbui](https://github.com/AFK-surf/still.fail): the UI and logic are written once, and what is system-specific is a
native layer in `app/` for Windows and macOS.

![PinShot](site/public/img/en-markup.jpg)

## macOS

Requires macOS 14 or later on Apple silicon. Download `PinShot-mac.zip` from [pin-shot.pages.dev](https://pin-shot.pages.dev) (or [Releases](https://github.com/motion-space/pinshot/releases/latest)), unzip it, move `PinShot.app` to Applications, and open it.
Click the camera in the menu bar or press Control–Option–A to capture. Control–2 pins a clipboard image.
Right-click the camera for settings and quit. In a selection, use ⌘C to copy, ⌘S to save, ⌘T to pin,
and ⌘Z / ⇧⌘Z to undo or redo.

On the first capture, allow PinShot under System Settings › Privacy & Security › Screen & System Audio Recording,
then quit and reopen it. If PinShot is missing from the list, click **+** and select the app. A rebuilt ad-hoc app can require granting access again.
Settings and logs live under `~/Library/Application Support/PinShot/`.

With the Xcode command-line tools and MoonBit on PATH, run `bash scripts/build-mac.sh` and then
`open out/build/PinShot.app`. The **macOS package** GitHub Actions workflow runs on demand and on
`v*` tags. Download the runner-architecture artifact for the app ZIP. These builds use ad-hoc signing
without a Developer ID certificate or notarization.

## Windows installation

Download `PinShot-Setup.exe` from [pin-shot.pages.dev](https://pin-shot.pages.dev) (or [Releases](https://github.com/motion-space/pinshot/releases/latest)) and run
it. It installs for the current user (no administrator needed), adds a Start menu entry and an uninstall entry in
Settings › Apps, and can start PinShot with Windows. `pinshot.exe` on the same page is the portable build: one file,
run it from anywhere.

The installer is not code-signed: Windows SmartScreen may say "Windows protected your PC"; choose More info › Run
anyway. Windows 10 2004 or later, x64.

## Use

- `Ctrl+Alt+A` (or click the tray icon): freeze the monitor under the pointer and capture (the shortcut can be changed
  in the settings)
  - Click without moving: select the window under the pointer; drag: select an area; drag edges and corners: resize;
    arrow keys: move the selection 1 px (Shift: 10 px)
  - Toolbar: shapes (rectangle / ellipse / focus), lines (arrow / line; Shift: horizontal, vertical or 45°), pen & eraser,
    mosaic & redaction (pixel mosaic, brush mosaic, blur), numbered marker, text, undo, extract text
    (`Ctrl+O`), pin, save, close, copy
  - `Enter`, `Ctrl+C` or double-click in the selection: copy; `Ctrl+S`: save (PNG lossless, JPEG high or JPEG compact);
    `Ctrl+T`: pin; `Ctrl+O`: extract text; `Ctrl+L`: scrolling screenshot (Windows); `Ctrl+R`: record area as MP4 (H.265/H.264) or GIF (Windows, with optional system audio, click/keycap overlay, and post-recording format/quality/size export); `Ctrl+Z` / `Ctrl+Y`: undo / redo; `C`: copy the colour under the pointer; `Ctrl+A`: the whole screen
  - Right-click: clear the selection, again to quit; `Esc`: quit
- Pins: drag to move; drag any edge or corner to resize keeping aspect ratio (`Shift`: stretch freely), the wheel to zoom;
  `Ctrl+wheel` for opacity; double-click or `Esc` to close; the right-click menu has copy, save as, extract text, always on top,
  rotate left / right 90° (`Ctrl+Shift+R` / `Ctrl+R`), flip horizontally / vertically, reset (`Ctrl+0`), opacity,
  close all
- Extract text: the words in the selection or the pin, read by Windows' own OCR (offline; Chinese first where its OCR is
  installed, it reads the English and digits among it too), shown in a window to correct and copy
- `Ctrl+2`: pin the image on the clipboard
- Tray menu: capture, pin clipboard, show / hide all pins, settings, open the screenshots folder, check for updates,
  quit
- Updates: Settings › About has **Check for updates** and an **Automatic updates** switch (off by default). Turned on,
  PinShot asks [pin-shot.pages.dev](https://pin-shot.pages.dev/dl/latest.json) once a day, downloads a new version in
  the background, checks its SHA-256 and installs it once PinShot is idle (no capture, no pins open, nothing touched for
  two minutes), then starts again. Each release is signed (ECDSA P-256; the public key is built into PinShot): a release
  whose signature does not check out is never downloaded, so whoever could change the files on the download site still
  cannot get PinShot to run anything. An update that fails leaves the current version running. The installed copy updates through its installer (silently, keeping your choices);
  the portable `pinshot.exe` replaces itself. Left off, PinShot goes online only when you press Check for updates. The
  Microsoft Store package is updated by the Store and never checks itself.
- Command line: `pinshot.exe --settings`, `pinshot.exe --quit`, `pinshot.exe --bench` (times the capture),
  `pinshot.exe --ocr <picture>` (prints the text in a picture)

Settings are in `%APPDATA%\PinShot\settings.json`, the log (each capture's timings) in `%APPDATA%\PinShot\pinshot.log`.

## How it works

- One resident process. The frozen-screen overlay is mbui's main window (hidden between captures); each pin and the
  settings are mbui child windows in the same process.
- Each monitor keeps a Windows.Graphics.Capture session holding only its latest frame; as the shortcut is pressed that
  frame is copied to a staging texture (a few ms). A frame older than 5 s is not trusted: the session is made again and
  its first frame waited for. Sessions are also made again as monitors wake, on resume and unlock. HDR monitors are
  captured in FP16 and brought back to SDR by the SDR white level on the GPU. GDI BitBlt is the fallback;
  `PINSHOT_CAPTURE=gdi` turns the resident sessions off.
- `patches/mbui-pinshot.patch`: lets mbui make a texture straight from those pixels, and makes its glyph atlas
  1024² instead of 4096² (64 MB of video memory).
- Marks are kept in monitor pixels; the overlay and the export draw the same nodes, and the export is composed on the
  GPU at the original resolution by mbui's `take_picture`.

## Windows build

Needs Visual Studio 2022 (C++), Git for Windows (Git Bash) and MoonBit (`moon` on PATH).

```powershell
scripts/build.ps1            # out/build/pinshot.exe (warnings are errors)
scripts/install.ps1          # installs it for you and starts it
packaging/pack-setup.ps1     # out/setup/PinShot-Setup-<version>.exe (Inno Setup 6)
packaging/pack-msix.ps1      # the Microsoft Store package
```

`scripts/fetch-stillfail.sh` (run by the build) fetches still.fail's `apps/mbui` and `libs/mbui` at the commit in
`stillfail.lock` into `deps/stillfail` and applies `patches/`.

## Sponsor

PinShot is free. If it helps you, you can support it on the [sponsor page](https://pin-shot.pages.dev/support) (WeChat Reward, Ko-fi), also under Settings › About.

## License

[MIT](LICENSE). The shutter sound (`assets/shutter.wav`) was generated with ElevenLabs.

---

## 中文

截图、标注、贴图（PixPin 式）的 Windows 和 macOS 工具，用 MoonBit 和 still.fail 的 mbui 写成：界面和逻辑只写一份，系统相关的部分是很薄的原生层。

### macOS

需要 macOS 14 或更新版本、Apple 芯片。在 [pin-shot.pages.dev](https://pin-shot.pages.dev)（或 [Releases](https://github.com/motion-space/pinshot/releases/latest)）下载 `PinShot-mac.zip`，解压，把 `PinShot.app` 移到「应用程序」后打开。
点菜单栏的相机或按 ⌃⌥A 截图，⌃2 贴剪贴板图片，右键相机打开设置或退出。选区内支持 ⌘C 复制、⌘S 保存、⌘T 贴图、⌘Z 撤销和 ⇧⌘Z 重做。

首次截图时，在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」（部分系统显示为「屏幕录制」）中允许 PinShot，然后退出并重新打开应用。列表为空时，点「＋」选择当前的 `PinShot.app`。重新构建后，系统可能需要对新版重新授权。设置与日志在 `~/Library/Application Support/PinShot/`。

本机安装 Xcode 命令行工具和 MoonBit 后，运行 `bash scripts/build-mac.sh`，用 `open out/build/PinShot.app` 启动。在 GitHub Actions 中可手动运行 **macOS package**，推送 `v*` 标签也会打包。产物使用 ad-hoc 签名，尚未使用开发者证书和公证。

### Windows 安装

在 [pin-shot.pages.dev](https://pin-shot.pages.dev)（或 [Releases](https://github.com/motion-space/pinshot/releases/latest)）下载 `PinShot-Setup-<版本>.exe` 运行即可：装在当前用户下，不需要管理员权限，会建开始菜单快捷方式、在「设置 › 应用」里加卸载项，可选开机自启。同一页的 `pinshot.exe` 是免安装版，单个文件，放哪里都能直接运行。

安装包没有代码签名，第一次运行时 SmartScreen 可能提示「Windows 已保护你的电脑」，点「更多信息 › 仍要运行」。需要 Windows 10 2004 及以上、x64。

### 用法

- `Ctrl+Alt+A`（或点托盘图标）：冻结鼠标所在的显示器进入截图（设置里可换快捷键）
  - 不动鼠标点一下选中窗口；拖动框选；拖边和角调整大小；方向键移动 1 像素（Shift 10 像素）
  - 工具条：形状（矩形 / 椭圆 / 聚焦）、线条（箭头 / 直线，按住 Shift 只走水平、垂直或 45°）、画笔与橡皮擦、打码（像素框选 / 涂抹马赛克 / 模糊遮罩）、序号、文字、撤销、提取文字（`Ctrl+O`）、贴图、保存、关闭、复制
  - `Enter`、`Ctrl+C` 或在选区里双击：复制；`Ctrl+S` 保存（设置里可选 PNG 无损 / JPEG 高清 / JPEG 小体积）；`Ctrl+T` 贴图；`Ctrl+O` 提取文字；`Ctrl+L` 长截图（Windows）；`Ctrl+R` 区域录屏 MP4（H.265/H.264）或 GIF（Windows，支持系统声音、键鼠显示与录后格式/画质/尺寸压缩导出）；`Ctrl+Z` / `Ctrl+Y` 撤销 / 重做；`C` 复制鼠标下的颜色；`Ctrl+A` 选中整个屏幕
  - 右键先取消选区，再右键退出；`Esc` 退出
- 贴图：拖动移动；拖任意边或角等比缩放（按住 `Shift` 自由拉伸）、滚轮缩放；`Ctrl+滚轮` 调透明度；双击或 `Esc` 关闭；右键菜单有复制、另存为、提取文字、置顶、向左 / 向右旋转 90°（`Ctrl+Shift+R` / `Ctrl+R`）、水平 / 垂直翻转、重置（`Ctrl+0`）、不透明度、关闭全部
- 提取文字：用 Windows 自带的 OCR 识别选区或贴图里的文字（不联网；装了中文 OCR 就优先用中文，里面的英文和数字也能认），在弹出的窗口里改、复制
- `Ctrl+2`：把剪贴板里的图片贴到屏幕上
- 托盘右键：截图、贴剪贴板图片、显示 / 隐藏全部贴图、设置、打开截图文件夹、检查更新、退出
- 更新：「设置 › 关于」里有「检查更新」按钮和「自动更新」开关（默认关）。打开后每天向 pin-shot.pages.dev 查一次新版本，后台下载、校验 SHA-256，等 PinShot 空闲（没在截图、没有贴图、两分钟没动键鼠）时安装并重新启动。每个版本都有签名（ECDSA P-256，公钥内置在 PinShot 里）：签名对不上就不下载，即使下载站的文件被人改了，也没法让 PinShot 运行别的程序。更新失败时，当前版本照常运行。安装版通过安装包静默升级（保留原来的选项），免安装版直接替换自己。关着时只有点「检查更新」时才联网。Microsoft Store 版由商店更新，自己不检查。

设置在 `%APPDATA%\PinShot\settings.json`，日志在 `%APPDATA%\PinShot\pinshot.log`。

### Windows 构建

需要 Visual Studio 2022（C++）、Git for Windows、MoonBit（`moon` 在 PATH 上），命令见上面的 Build 一节。

### 赞助

PinShot 免费使用。觉得好用的话，可以在[赞助页](https://pin-shot.pages.dev/support?lang=zh)请作者喝杯咖啡（微信赞赏），「设置 › 关于」里也有入口。

### 许可证

[MIT](LICENSE)。快门声（`assets/shutter.wav`）由 ElevenLabs 生成。
