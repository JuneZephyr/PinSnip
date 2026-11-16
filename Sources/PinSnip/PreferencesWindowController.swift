import AppKit

/// The only two preferences: the three global hotkeys and launch at login.
final class PreferencesWindowController: NSObject {

    private var window: NSWindow!
    private let captureField = HotKeyField()
    private let pasteField = HotKeyField()
    private let hideAllField = HotKeyField()
    private let loginCheckbox = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)

    private var original: (capture: HotKeyCombo, paste: HotKeyCombo, hideAll: HotKeyCombo)

    override init() {
        let preferences = AppEnvironment.shared.preferences
        original = (preferences.capture, preferences.paste, preferences.hideAll)
        super.init()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 216),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "PinSnip 偏好设置"
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 216))
        window.contentView = content

        content.addSubview(label("截图", at: NSPoint(x: 24, y: 168)))
        content.addSubview(label("贴剪切板", at: NSPoint(x: 24, y: 130)))
        content.addSubview(label("隐藏全部贴图", at: NSPoint(x: 24, y: 92)))

        for (field, y) in [(captureField, 168), (pasteField, 130), (hideAllField, 92)] {
            field.frame = NSRect(x: 150, y: y, width: 160, height: 24)
            content.addSubview(field)
        }

        loginCheckbox.frame = NSRect(x: 150, y: 54, width: 180, height: 22)
        content.addSubview(loginCheckbox)

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.frame = NSRect(x: 250, y: 16, width: 80, height: 28)
        content.addSubview(cancelButton)

        let saveButton = NSButton(title: "存储", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 340, y: 16, width: 70, height: 28)
        content.addSubview(saveButton)
    }

    private func label(_ text: String, at point: NSPoint) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(origin: point, size: NSSize(width: 110, height: 22))
        field.alignment = .right
        return field
    }

    func show() {
        let preferences = AppEnvironment.shared.preferences
        captureField.combo = preferences.capture
        pasteField.combo = preferences.paste
        hideAllField.combo = preferences.hideAll
        loginCheckbox.state = LoginItem.isEnabled ? .on : .off

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func cancel() {
        window.orderOut(nil)
    }

    @objc private func save() {
        let preferences = AppEnvironment.shared.preferences

        let proposed: [(name: String, combo: HotKeyCombo)] = [
            ("截图", captureField.combo ?? original.capture),
            ("贴剪切板", pasteField.combo ?? original.paste),
            ("隐藏全部贴图", hideAllField.combo ?? original.hideAll)
        ]

        // Carbon never reports that another application already owns a
        // combination, so the only clash we can detect is two of our own groups
        // sharing one. Refuse to save that and name the groups involved.
        for i in proposed.indices {
            for j in (i + 1)..<proposed.count where proposed[i].combo == proposed[j].combo {
                showDuplicateWarning(
                    "「\(proposed[i].name)」和「\(proposed[j].name)」用了同一个快捷键 "
                    + proposed[i].combo.displayName + "。请换掉其中一个，设置没有保存。"
                )
                return
            }
        }

        preferences.capture = proposed[0].combo
        preferences.paste = proposed[1].combo
        preferences.hideAll = proposed[2].combo

        let failed = AppEnvironment.shared.lastRegistrationFailures
        if !failed.isEmpty {
            // Put the working combinations back and say which group is taken.
            preferences.capture = original.capture
            preferences.paste = original.paste
            preferences.hideAll = original.hideAll
            AppEnvironment.shared.showRegistrationConflict(failed)
            return
        }

        let wantsLogin = loginCheckbox.state == .on
        preferences.launchAtLogin = wantsLogin
        if !LoginItem.setEnabled(wantsLogin) {
            showLoginWarning()
        }
        window.orderOut(nil)
    }

    private func showDuplicateWarning(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "快捷键重复"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showLoginWarning() {
        let alert = NSAlert()
        alert.messageText = "登录时启动设置失败"
        alert.informativeText = "系统没有接受登录项注册。你可以在 系统设置 › 通用 › 登录项 中手动添加 PinSnip。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
