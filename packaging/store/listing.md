# PinShot — Microsoft Store submission (1.0.0)

Free · no ads · no in-app purchases · category Productivity › Utilities & tools (or Photo & video) · age rating: IARC
questionnaire, no user interaction, no data shared, no network access · privacy: the app collects nothing and never
connects to the network (no privacy policy URL needed; if Partner Center insists, point at a page saying so).

## Restricted capabilities: why each is needed (Partner Center › Submission options › "Why do you need…")

> **runFullTrust**
> PinShot is a desktop app (Win32, packaged with MSIX). It lives in the notification area, registers global shortcuts
> (Ctrl+Alt+A to take a screenshot, Ctrl+2 to pin the clipboard's image), shows a full-screen capture overlay and
> pinned images as always-on-top windows of its own, and reads and writes the clipboard. These are Win32 APIs that need
> a full-trust process.
>
> **graphicsCaptureProgrammatic**
> PinShot is a screenshot tool: the moment the user presses its shortcut, it freezes what is on the screen so they can
> pick a part of it. To make that instant (about 50 ms, with HDR colours right), it keeps a Windows.Graphics.Capture
> session of each display and copies the latest frame when the shortcut is pressed, without the system picker, which
> would defeat a screenshot taken with one key. Nothing is recorded or kept between screenshots: frames are only held
> in GPU memory and replaced as the screen changes; a screenshot is copied, saved or pinned only when the user says so,
> and never leaves the PC.
>
> **graphicsCaptureWithoutBorder**
> Windows draws a yellow border around a captured display. PinShot keeps its capture session open so the screenshot
> is ready the instant the shortcut is pressed, so the border would stay on screen all the time and cover what the user
> works on. Where borderless capture is not allowed, PinShot does not keep a session and takes each screenshot with
> GDI instead (slower), so no border is ever shown.

## English listing

**Product name:** PinShot

**Short description:**
Press Ctrl+Alt+A, pick a part of the screen, mark it up and copy, save or pin it on top of everything. Fast, light,
free.

**Description:**
PinShot is a screenshot tool that gets out of your way.

Press Ctrl+Alt+A and the screen freezes in about 50 ms. Hover to pick a window, or drag to pick any area; the
magnifier shows every pixel and its colour. Then mark it up and press Enter to copy it, Ctrl+S to save it, or Ctrl+T to
pin it on top of your other windows, where it stays while you work.

• Rectangles, ellipses, arrows and straight lines (hold Shift for horizontal, vertical or 45°), pen, numbered steps,
  text, mosaic and a focus tool that dims everything but what matters
• Select any mark to move it, reshape it, change its colour or thickness, or delete it; undo and redo
• Pins: drag to move, scroll to zoom, Ctrl+scroll to fade, right-click for copy, save, always on top and more; Ctrl+2
  pins the image on the clipboard
• Accurate colours on HDR displays
• English and Chinese
• Free, no ads, works offline and collects no data

**Keywords:** screenshot, screen capture, snipping, pin, annotate, markup, mosaic, clipboard, HDR

**What's new in this version:** First release.

## 中文商店介绍

**产品名：** PinShot

**简短描述：**
按 Ctrl+Alt+A，框选屏幕，标注后复制、保存，或者贴在所有窗口最上面。快、轻、免费。

**描述：**
PinShot 是一个不打扰你的截图工具。

按下 Ctrl+Alt+A，约 50 毫秒屏幕就定格。鼠标悬停自动选中窗口，拖动可以框选任意区域，放大镜显示每个像素和它的颜色。标注完按
Enter 复制、Ctrl+S 保存、Ctrl+T 贴图——贴图会一直浮在其他窗口上面，方便你边看边工作。

• 矩形、椭圆、箭头、直线（按住 Shift 水平、垂直或 45°）、画笔、序号、文字、马赛克，还有把重点之外都调暗的「聚焦」
• 选中任何标注都能移动、改形状、改颜色和粗细、删除；支持撤销和重做
• 贴图：拖动移动，滚轮缩放，Ctrl+滚轮调透明度，右键复制、保存、置顶等；Ctrl+2 把剪贴板里的图片直接贴出来
• HDR 屏幕下颜色准确
• 中文、英文界面
• 免费、无广告，不联网、不收集任何数据

**关键词：** 截图、截屏、贴图、标注、马赛克、剪贴板、HDR

**新版本说明：** 首个版本。
