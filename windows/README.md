# PinSnip for Windows

Windows 版的 PinSnip：一个常驻通知区域的截图 + 贴图工具。快捷键截图、标注、长截图，把剪切板里的图片或文字贴在任何窗口上方。

这是 macOS 版（仓库根目录的 Swift 工程）的移植，**独立工程，不引用也不修改 macOS 源码**。

## 系统要求

- Windows 10 1903 或更新（64 位），Windows 11 均可
- 推荐 Windows 10 2004 及以上：从这一版开始可以把 PinSnip 自己的窗口从屏幕截图里排除；更旧的系统会在截图瞬间先隐藏贴图窗口，效果相同
- 不需要管理员权限，不需要单独的"屏幕录制"授权（Windows 没有这个机制）

## 构建

需要 .NET 8 SDK（更高版本的 SDK 也可以，只要装了 net8.0 的引用包）：

```
winget install Microsoft.DotNet.SDK.8
```

发布成单个 exe（在 `windows/` 目录下执行）：

```
dotnet publish src/PinSnip/PinSnip.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -o artifacts
```

产物是 `artifacts/PinSnip.exe`，约 70 MB，自带运行时，目标机器不需要装 .NET。

首次运行时 Windows SmartScreen 会提示"已保护你的电脑"，因为程序没有代码签名证书：点**更多信息 → 仍要运行**。之后不会再提示。

## 使用

启动后只在通知区域出现一个蓝色图标，没有主窗口。

| 操作 | 默认快捷键 |
| --- | --- |
| 区域截图 | `F1` |
| 贴剪切板（图片 → 文字 → 图片文件） | `F3` |
| 隐藏 / 显示所有贴图 | `Shift+F3` |
| 销毁所有贴图 | `Shift+Esc` |

快捷键可以在「偏好设置」里改，两个快捷键重复时会拒绝保存并说明原因。

### 截图

- `F1` 冻结所有屏幕，在冻结画面上拖出选区；多屏时每块屏幕各自覆盖。
- 回车或双击选区内复制到剪切板；`Esc` 或右键取消；`Ctrl+S` 保存 PNG；`Ctrl+T` 贴到屏幕。
- 选区确定后出现工具栏：矩形、椭圆、箭头、画笔、文字、马赛克、撤销、颜色、线宽。
- 画完的标注可以按住再拖动；点中以后，颜色和线宽直接改在这一条上。`Ctrl+Z` 或工具栏的「撤销」回退上一步。
- 选区边角可以拖动调整，选区内可以整体拖动，选区外再拖就是重新选择。
- 截图按物理像素裁切：150% 缩放的屏幕上，选区与最终图片逐像素对齐。

### 长截图

选区确定后点「长截图」：

- **手动（默认）**：自己拖动页面或滚动滚轮，工具只追加新出现的行。不会误判"到底"，对不齐的页面会跳过并提示。高度上限约为 20 个选区高。
- **自动**：点预览面板上的「自动滚动」，工具向选区下方的窗口发送滚轮消息；两帧不再变化即认为到底，对不齐则停止。
- 总高度上限 30000 px。结束后可回车复制或保存；长截图期间回车和 Esc 由 PinSnip 接收，不会漏给下面的页面。

### 贴图

- `F3` 把剪切板内容贴到屏幕上；文字会渲染成浅色卡片。
- 拖动移动，滚轮缩放，双击关闭。
- 贴图不会抢键盘焦点，也不会出现在截图里。
- 密码管理器标记为隐藏的剪切板内容会被跳过。

## 与开发方案的技术差异

方案里写的截图后端是 `Windows.Graphics.Capture`。这一版先用 GDI 的 `CopyFromScreen`（整屏冻结、物理像素）：

- 不引入任何第三方包（WGC 在 .NET 里需要 D3D11 设备与帧池的 COM 互操作），单文件自包含发布更稳；
- 截图只经过 `Capture/ScreenCapture.cs` 一个文件，将来换成 WGC 只改这一处；
- 首版在 Windows 10 1903 上也能用。

其余按方案：`RegisterHotKey` 全局快捷键、`WindowFromPoint` + `WM_MOUSEWHEEL` 自动滚动、`WDA_EXCLUDEFROMCAPTURE` 排除自身窗口、自包含单文件 exe、独立 `windows/` 工程、不改动 macOS 源码。

## 目录

```
windows/
├─ src/PinSnip/
│  ├─ Program.cs              入口，单实例
│  ├─ App.cs                  托盘、快捷键、截图与长截图会话
│  ├─ TrayIcon.cs             通知区域图标与菜单
│  ├─ Capture/                GDI 截图、剪贴板、位图转换
│  ├─ Selection/              覆盖窗口、选区、标注、文字输入
│  ├─ LongCapture/            拼接算法、长截图循环、预览面板
│  ├─ Pins/                   贴图窗口与贴图管理
│  ├─ Platform/               Win32 调用、全局快捷键、Shift+Esc 监听
│  └─ Settings/               设置文件、开机启动、偏好设置窗口
└─ src/PinSnip/app.manifest   每显示器 DPI 感知、无需管理员
```

## 已知限制

- **150% / 200% 缩放下必须先在真机上验证选区与裁切**（开发方案的第 1 阶段验收条件）。代码按物理像素工作，但 Windows 的 DPI 行为只能在 Windows 上确认。
- 自动滚动依赖目标窗口处理 `WM_MOUSEWHEEL`。部分应用（某些 Electron 程序、游戏）可能不响应，此时请用手动模式。
- 马赛克目前只有框选块状马赛克，没有涂抹和模糊。
- `Shift+Esc` 通过低级键盘钩子监听，只在存在贴图时安装，**只监听不拦截**，按键仍会传给当前程序。个别安全软件可能会对键盘钩子弹出提示。

## 隐私

- 不联网、无账号、无遥测。
- 截图和贴图只在内存里，保存需要你手动选择路径；复制走系统剪切板。
- 设置保存在 `%APPDATA%\PinSnip\settings.json`，出错时会在同一目录写 `pin-snip.log`。没有别的文件。

## 许可

MIT，见仓库根目录的 LICENSE。
