# 参与开发

欢迎 Issue 和 PR。这个项目很小，只有一条硬规则：**不要引入联网**。截图工具能看到的画面太多，任何网络请求都会破坏「只在内存和剪切板」的承诺。

## 环境

- macOS 14 或更新
- Xcode 或 Command Line Tools（Swift 5.10+）
- 不需要 Node，`package.json` 只是几个便捷命令；也可以直接 `swift build`

## 构建与运行

```bash
swift build -c release   # 只编译
npm run build            # 编译并组装 dist/PinSnip.app（会创建本地签名身份，见 SECURITY.md）
npm run launch           # 构建并打开
npm run dmg              # 构建并打包 release/PinSnip-<版本>.dmg（会先退出正在运行的 PinSnip）
```

调试时不要直接运行 `dist/PinSnip.app/Contents/MacOS/PinSnip`：图形界面的程序会一直占住终端，看起来像卡死。

## 代码结构

| 文件 | 作用 |
| --- | --- |
| `main.swift` / `AppDelegate.swift` | 菜单栏应用入口（`LSUIElement`，无 Dock 图标） |
| `AppEnvironment.swift` | 菜单栏、权限提示、全局快捷键、偏好设置的接线 |
| `HotKeyManager.swift` / `HotKey.swift` / `HotKeyField.swift` | 系统快捷键注册与快捷键录制控件 |
| `CaptureEngine.swift` | ScreenCaptureKit 抓取整屏、按缩放裁剪 |
| `SelectionController.swift` | 一次截图会话：遮罩、拖框、工具条、标注、长截图、退出 |
| `Overlay.swift` | 冻结画面 + 选区绘制的全屏窗口 |
| `SelectionToolbar.swift` / `ToolOptionsBar.swift` | 图标工具条与每个工具的选项胶囊 |
| `Annotation.swift` | 形状、箭头、画笔、文本、马赛克与合成到成图 |
| `LongCapture.swift` / `Stitch.swift` / `ScrollSender.swift` | 长截图的滚动循环、拼接算法、发送滚轮事件 |
| `PreviewPanel.swift` | 长截图右侧预览 |
| `PinManager.swift` / `PinWindow.swift` | 贴图窗口、最近关闭一张、隐藏全部 |
| `Clipboard.swift` / `TextCard.swift` | 读取剪切板（跳过密码管理器标记）与文字卡片渲染 |
| `Preferences*.swift` / `LoginItem.swift` / `Permissions.swift` | 设置、登录项、权限检查 |
| `Geometry.swift` | 两套坐标系（Cocoa y 向上 / CoreGraphics y 向下）的换算 |

## 约定

- 只用 AppKit + Swift，不引入第三方依赖。
- 所有图像数据留在内存，不写历史文件，不发网络请求。
- 界面文字是简体中文；代码注释用英文短句，说明「为什么」而不是「做了什么」。
- 改完先 `npm run build`，确认没有新的编译警告。

## 测什么

改截图、权限或长截图相关代码时，至少手动过一遍：

1. 多屏 + Retina：选区选中的像素与最终图一致，边缘不糊。
2. F1/F3 在其他应用前台时仍然生效。
3. 标注：形状/箭头/画笔/文本/马赛克各画一次，复制出来的图里位置正确。
4. 一个超过三屏的网页：长截图拼接是否有明显错位或重复，到页面底部是否自动停止。
5. 贴图：拖动、滚轮缩放、双击关闭、Esc/⌘W/⇧Esc、F3 找回最近关闭的一张。
