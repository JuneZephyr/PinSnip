# 安全说明

## 支持范围

| 版本 | 状态 |
| --- | --- |
| 1.0.x | 接收安全报告 |

## 这个应用需要哪些系统权限

PinSnip 是本地工具，权限是 macOS 对截图类软件的硬性要求：

| 权限 | 是否必须 | 用途 | 没有时会怎样 |
| --- | --- | --- | --- |
| 屏幕录制 | 必须 | 抓取选中区域的像素 | 截图拿到空白，应用会提示去开启 |
| 辅助功能 / 事件合成 | 只有长截图需要 | 向选区下方的窗口发送向下滚动的滚轮事件 | 普通截图、标注、贴图仍可用，长截图入口不可用 |
| 登录时启动（可选） | 否 | 用 `SMAppService` 注册登录项 | 不影响其他功能 |

代码里没有申请麦克风、摄像头、通讯录、定位、自动化（Apple Events）、全磁盘访问。

## 代码里与安全相关的地方

这几处是审核或使用前值得了解的：

1. **全局快捷键**：`RegisterEventHotKey`（Carbon）。会独占 F1/F3/⇧F3 这三个组合，其他应用收不到；这是截图工具的正常行为。冲突无法被系统报告，所以应用只能检测自身三组快捷键是否重复。
2. **键盘旁观监听**：`NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`。只旁观、不能拦截，作用范围限定在「指针停在贴图上按 Esc/⌘W」和长截图期间的回车/Esc，不记录输入。
3. **向其他应用发送事件**：`CGEvent.postToPid(_:)`，仅长截图使用，仅滚轮上下滚动，位置固定在选区中心，目标进程是选区下方那个窗口。
4. **读取剪切板**：仅在按 F3 时；带 `ConcealedType` 标记的内容直接拒绝。
5. **没有动态加载、没有子进程执行**：源码中没有 `Process`、`NSTask`、`NSAppleScript`、`dlopen`。

## 构建脚本会创建一个本地签名身份

`scripts/ensure-signing-identity.sh` 会在你的登录钥匙串里创建一个名为 **“PinSnip Local”** 的自签名证书，并有两点需要知道：

- 它用 `security import ... -A` 导入，意味着本机上的进程可以在不弹窗的情况下使用这个私钥签名。如果你介意，可以改成不带 `-A`（每次构建会弹一次授权），或者完全不看这个脚本、只做 `swift build`。
- 它的目的是让**本地**构建的签名保持稳定，这样 macOS 不会每次重新构建都丢掉你授予的屏幕录制权限。它只用于本地开发；发布用的 dmg 也是用它签的，所以其他机器上 Gatekeeper 会提示「无法验证开发者」，需要右键 → 打开。

不想要这个身份时可以删掉：

```bash
security delete-identity -c "PinSnip Local"
# 证书本体还在钥匙串里的话，在「钥匙串访问」里搜索 PinSnip Local 一并删除
```

## 发布包的真实性

- 目前没有 Apple Developer ID 签名，也没有公证。**不要因此关闭 Gatekeeper 的全局保护**；只对这一个应用右键 → 打开，或在确认来源后执行 `xattr -dr com.apple.quarantine /Applications/PinSnip.app`。
- Release 里的 dmg 是用本地自签名证书签的，校验方式只有「和 GitHub 上的源码构建结果对比」。最稳妥的用法是从源码自己构建。

## 报告问题

- 一般问题：开一个 Issue。
- 涉及安全（例如能让应用越权读取、执行或泄露内容）：用 GitHub 的 **Report a vulnerability**（Security → Advisories），不要先公开发 Issue。
