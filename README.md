# PinSnip

macOS 菜单栏截图 + 贴图工具：区域截图、标注、长截图、把图片或文字钉在屏幕最上层。

**没有网络、没有账号、没有历史记录。** 截图和贴图只存在于内存和系统剪切板，退出应用即消失。

*PinSnip is a menu-bar screenshot and pin tool for macOS. Everything stays in memory and the system clipboard — no network, no accounts, no telemetry.*

## 功能

- **区域截图**：F1 抓取每个屏幕的一帧，在冻结画面上拖选；多屏分别覆盖，Retina 输出原生像素。
- **标注**：形状、箭头、画笔、文本、马赛克（框选 / 涂抹 / 自动 / 模糊）。
- **复制、保存、贴到屏幕**：回车或双击复制并退出，⌘T 贴到屏幕上，⌘S 保存 PNG。
- **长截图**：手动滚动或自动向下滚动，只追加新出现的行并拼接；到页面底部、到高度上限或对不齐时自动停止，已拼的部分保留。
- **贴图**：F3 把剪切板里的图片或文字钉在屏幕上；可拖动、滚轮缩放、边缘拉伸、隐藏全部、销毁。
- **菜单栏常驻**：不进 Dock，全局快捷键在其他应用前台时也能用；登录时启动可选。

## 安装

1. 到 [Releases](https://github.com/JuneZephyr/PinSnip/releases) 下载最新的 `PinSnip-<版本>.dmg`，打开后把 PinSnip 拖进「应用程序」。
2. **第一次打开可能被 Gatekeeper 拦下**：这个版本没有 Apple 开发者签名，也没有公证。在 Finder 里按住 Control 点图标 →「打开」，或在终端执行一次：

   ```bash
   xattr -dr com.apple.quarantine /Applications/PinSnip.app
   ```

   不要为了它关闭 Gatekeeper 的全局保护。
3. 第一次截图时 macOS 会要求「屏幕录制」权限；到 系统设置 › 隐私与安全性 › 屏幕录制 打开 PinSnip，然后**完全退出并重新打开**应用。

当前 Release 是 **Apple Silicon（arm64）** 构建；Intel 机器请按下面的步骤从源码构建。

## 权限

| 权限 | 是否必须 | 用来做什么 | 没有时 |
| --- | --- | --- | --- |
| 屏幕录制 | 是 | 抓取你选中区域的画面 | 截图是空白，应用会引导你去开启 |
| 辅助功能 / 事件合成 | 只有长截图 | 向选区下方的窗口发送向下滚动 | 普通截图、标注、贴图照常可用 |
| 登录时启动 | 否 | 开机自动运行 | 不影响其他功能 |

不需要麦克风、摄像头、通讯录、定位、自动化或全磁盘访问。

在较新的 macOS 上，第一次按 F3 读取剪切板时系统可能还会问「允许 PinSnip 从其他应用粘贴」，选允许即可；之后不会再问。

## 从源码构建

需要 macOS 14 或更新、Xcode 或 Command Line Tools。

```bash
git clone https://github.com/JuneZephyr/PinSnip.git
cd PinSnip
npm run build     # 编译并组装 dist/PinSnip.app
npm run launch    # 构建并打开
npm run dmg       # 打包 release/PinSnip-<版本>.dmg
```

也可以只用 SwiftPM：

```bash
swift build -c release
```

几点说明：

- `package.json` 只是几个便捷命令，没有 Node 依赖。
- `npm run build` 会在你的登录钥匙串里创建一个名为「PinSnip Local」的本地签名证书，让每次构建的签名保持一致，这样 macOS 不会每次重新构建都丢掉屏幕录制权限。它只用于本机，细节和删除方法见 [SECURITY.md](SECURITY.md)。
- 不要直接运行 `dist/PinSnip.app/Contents/MacOS/PinSnip`：图形界面的程序会一直占住终端，看起来像卡死。

## 快捷键

| 作用 | 快捷键 |
| --- | --- |
| 截图 | F1 |
| 复制并退出 | 回车，或在选区内双击 |
| 贴到屏幕上 | ⌘T |
| 开始长截图 | L |
| 保存成文件 | ⌘S |
| 取消 | Esc 或右键 |
| 贴剪切板内容 | F3 |
| 隐藏 / 显示全部贴图 | ⇧F3 |
| 关闭当前贴图 | 双击；或把指针放在贴图上按 Esc / ⌘W |
| 销毁当前贴图 | 把指针放在贴图上按 ⇧Esc |

三个全局快捷键（F1 / F3 / ⇧F3）可以在 偏好设置 里改。系统不告诉应用「这个组合已被别的软件占用」，所以只能检测本工具内部是否重复：重复时会拒绝保存并指出是哪两组。

## 标注

选好区域后，工具条左边有五个工具：形状、箭头、画笔、文本、马赛克。点一个工具，它下面会弹出对应的选项（颜色、粗细、大小、像素大小等）。

- 在选区内拖动就是画；点了某个工具以后，选区不能拖动，想移动选区请先再点一次那个工具把它关掉。
- 文本工具：在选区内点一下开始输入，回车或 Esc 结束输入，文字会留在图上。
- 马赛克可以框选或涂抹，也可以点「自动」把整个选区打码；「清除」去掉所有马赛克。
- 标注只出现在最终复制 / 保存 / 贴到屏幕上的图里。

## 隐私

- 源码里没有任何网络请求：没有 `URLSession`、`Network`、`CFNetwork`、socket，也没有第三方 SDK。
- 屏幕画面、剪切板内容、贴图只在内存中；只有你按 ⌘S 并选择位置时才会写文件。
- 唯一的磁盘设置是快捷键和「登录时启动」，存在系统 `UserDefaults` 里。
- 贴图窗口不会被截进截图里。
- F3 会跳过密码管理器标记为「隐藏」（`org.nspasteboard.ConcealedType`）的剪切板内容。

完整的数据流见 [PRIVACY.md](PRIVACY.md)。

## 已知限制

- **长截图**：固定在顶部/底部的导航栏和输入框会在每一屏重复出现；视频、轮播图、闪烁的光标会让画面无法对齐，此时工具会停下并保留已拼的部分；懒加载的图片可能缺失。横向方向暂不支持拼接。
- **快捷键冲突**：F1/F3 与其他截图或功能键软件可能撞车，系统不会报告，只能自己在偏好设置里改。
- **签名**：目前没有 Developer ID 签名和公证，其他机器上需要右键打开；最稳妥的用法是自己从源码构建。
- **系统保护**：贴图停在普通窗口之上、程序坞和菜单栏之下，不会盖住系统密码框，也不会留在锁屏或屏幕保护程序上面。
- 长截图功能在真实滚动页面上的表现仍在持续收集反馈（见 Issues）。

## 参与

- 问题和建议：[Issues](https://github.com/JuneZephyr/PinSnip/issues)
- 开发说明与代码结构：[CONTRIBUTING.md](CONTRIBUTING.md)
- 安全策略：[SECURITY.md](SECURITY.md)
- 更新记录：[CHANGELOG.md](CHANGELOG.md)

唯一不能破的规则：**不引入联网**。

## 许可

[MIT](LICENSE) © 2026 JuneZephyr
