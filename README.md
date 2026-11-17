# PinShot

截图、标注、贴图（PixPin 式），用 still.fail 的 mbui（MoonBit）写成：界面和逻辑只写一份，系统相关的部分是一层很薄的原生代码（Windows：`app/platform_win.c`；Mac 以后补一个同名接口的 `platform_mac.m`）。

## 用法

- `Ctrl+Alt+A`（或左键点托盘图标）：冻结当前显示器，进入截图（快捷键按本机 PixPin 的设置对齐，设置里可换成 `Ctrl+1`、`F1` 等）
  - 不动鼠标点一下：选中鼠标下的窗口；拖动：框选区域；拖边和角：调整大小；方向键：移动选区 1 像素（Shift 10 像素）
  - 工具条：矩形、椭圆、箭头、直线（箭头和直线按住 Shift 只走水平、垂直或 45°）、画笔、马赛克、序号、文字、撤销 / 重做、贴图、保存、关闭、复制
  - `Enter`、`Ctrl+C` 或在选区里双击：复制；`Ctrl+S`：保存；`Ctrl+T`：贴图；`Ctrl+Z` / `Ctrl+Y`：撤销 / 重做；`C`：复制鼠标下的颜色
  - 右键：先取消选区，再右键退出；`Esc`：退出
- 贴图：拖动移动；滚轮缩放；`Ctrl+滚轮` 调透明度；双击或 `Esc` 关闭；右键菜单里有复制、另存为、置顶、移到最前、原始大小、不透明度、关闭全部
- `Ctrl+2`：把剪贴板里的图片贴到屏幕上（同 PixPin）
- 托盘右键：截图、贴剪贴板图片、显示/隐藏全部贴图、设置、打开截图文件夹、退出
- 命令行：`pinshot.exe --settings` 打开设置，`pinshot.exe --quit` 退出正在运行的 PinShot，`pinshot.exe --bench` 测截屏耗时

设置存在 `%APPDATA%\PinShot\settings.json`，运行日志（每次截图的耗时）在 `%APPDATA%\PinShot\pinshot.log`。

## 结构

- 一个常驻进程。冻屏遮罩是 mbui 的主窗口（平时隐藏）；每张贴图、设置都是同一进程里的 mbui 子窗口，打开不再启动新进程。
- 每个显示器常驻一个 Windows.Graphics.Capture 会话，只持有最新一帧（不逐帧复制）；按下热键时把这一帧拷到 staging 纹理（约 3 ms），用 `mb_post` 通知界面；会话还没收到过帧时退回 GDI BitBlt（单独线程）。像素一直留在原生层，不复制到 MoonBit。`PINSHOT_CAPTURE=gdi` 关掉常驻会话。
- `patches/mbui-pinshot.patch`：让 mbui 直接用这块像素（或未压缩的 BMP）建纹理，跳过 WIC 转换和 mipmap。
- 标注都按显示器像素记录，遮罩和导出用同一套节点绘制；导出用 mbui 的 `take_picture` 在 GPU 上按原始像素合成成 PNG。
- 关闭截图后遮罩窗口缩到 16×16、清理 GPU 状态并 `IDXGIDevice3::Trim`，字形图集用 1024×1024（mbui 默认 4096×4096 要 64 MB 显存）。

## 构建

需要 Visual Studio 2022（C++）、Git Bash、MoonBit（`moon` 在 PATH 上）。

```powershell
scripts\build.ps1     # 产物 out\build\pinshot.exe（警告即错误）
scripts\install.ps1   # 装到 %LOCALAPPDATA%\Programs\PinShot 并启动
```

`scripts/fetch-stillfail.sh` 按 `stillfail.lock` 拉取 still.fail 的 `apps/mbui` 和 `libs/mbui` 到 `deps/stillfail`，再打上 `patches/` 里的补丁。
