import AppKit
import CoreGraphics
import Foundation

/// Application-wide wiring: menu bar, permissions, hotkeys and preferences.
final class AppEnvironment: NSObject {

    static let shared = AppEnvironment()

    let preferences = Preferences()
    let pins = PinManager()
    let selection = SelectionController()
    let hotkeys = HotKeyManager()

    var statusItem: NSStatusItem!

    /// Set after each registration pass so the preferences window can tell the
    /// user which group is already taken.
    private(set) var lastRegistrationFailures: [HotKeyManager.Tag] = []

    private var preferencesWindow: PreferencesWindowController?

    private override init() {
        super.init()
        selection.app = self

        CaptureEngine.shared.excludedWindowIDs = { [weak self] in
            guard let self else { return [] }
            var ids = self.pins.allWindowIDs()
            ids.append(contentsOf: self.selection.captureExclusionWindowIDs())
            return ids
        }

        preferences.onChange = { [weak self] in
            self?.applyPreferences()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hideAllPinsRequested),
            name: .pinHideAllRequested,
            object: nil
        )
    }

    func start() {
        hotkeys.install()
        applyPreferences()
        buildStatusItem()
        pins.startKeyMonitor()
        announceStartupIfNeeded()
    }

    /// A menu-bar-only app shows nothing at all when it launches, which reads
    /// as "it froze". Say that it is running, and point at the one permission
    /// that is still missing.
    private func announceStartupIfNeeded() {
        guard !Permissions.screenRecordingGranted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "PinSnip 已启动"
            alert.informativeText =
                "图标在屏幕右上角的菜单栏里（不在 Dock 中）。\n\n"
                + Permissions.screenRecordingHint
            alert.alertStyle = .informational
            alert.addButton(withTitle: "打开系统设置…")
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                self.openSystemSettings("Privacy_ScreenCapture")
            }
        }
    }

    // MARK: - Hotkeys

    private func applyPreferences(showConflictAlert: Bool = false) {
        let entries: [(tag: HotKeyManager.Tag, keyCode: UInt32, modifiers: UInt32, action: () -> Void)] = [
            (tag: .capture, keyCode: preferences.capture.keyCode,
             modifiers: preferences.capture.modifiers,
             action: { [weak self] in self?.startCapture() }),
            (tag: .paste, keyCode: preferences.paste.keyCode,
             modifiers: preferences.paste.modifiers,
             action: { [weak self] in self?.pasteFromClipboard() }),
            (tag: .hideAll, keyCode: preferences.hideAll.keyCode,
             modifiers: preferences.hideAll.modifiers,
             action: { [weak self] in self?.toggleHideAll() })
        ]
        lastRegistrationFailures = hotkeys.registerAll(entries)
        if showConflictAlert, !lastRegistrationFailures.isEmpty {
            showRegistrationConflict(lastRegistrationFailures)
        }
    }

    private func startCapture() {
        guard !selection.isActive else { return }
        selection.start()
    }

    private func pasteFromClipboard() {
        guard !selection.isActive else { return }
        pins.pasteClipboard()
    }

    private func toggleHideAll() {
        guard !selection.isActive else { return }
        pins.toggleHideAll()
    }

    @objc private func hideAllPinsRequested() {
        pins.hideAll()
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "截图")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "PinSnip 截图贴图"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        populate(menu)
        item.menu = menu
        statusItem = item
    }

    /// Fills a menu with the current titles and permission note.
    ///
    /// Called once when the status item is built, and again from
    /// `menuNeedsUpdate`, which AppKit uses to ask for fresh contents just
    /// before the item is opened. The menu object itself is never swapped while
    /// it is open — replacing it mid-tracking derails the menu.
    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !Permissions.screenRecordingGranted {
            addNote(Permissions.screenRecordingHint, to: menu)
        } else if !Permissions.canSendScrollEvents {
            addNote(Permissions.accessibilityHint, to: menu)
        }

        addItem(title: "截图（\(preferences.capture.displayName)）", action: #selector(menuCapture), to: menu)
        addItem(title: "贴剪切板（\(preferences.paste.displayName)）", action: #selector(menuPaste), to: menu)
        addItem(title: "隐藏全部贴图（\(preferences.hideAll.displayName)）", action: #selector(menuHideAll), to: menu)
        addItem(title: "偏好设置…", action: #selector(menuPreferences), to: menu)
        addItem(title: "退出", action: #selector(menuQuit), to: menu)
    }

    private func addNote(_ text: String, to menu: NSMenu) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = "点按「偏好设置」旁的说明可打开系统设置"
        menu.addItem(item)
        menu.addItem(.separator())
    }

    private func addItem(title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
    }

    @objc private func menuCapture() { startCapture() }
    @objc private func menuPaste() { pasteFromClipboard() }
    @objc private func menuHideAll() { toggleHideAll() }

    @objc private func menuPreferences() {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindowController()
        }
        preferencesWindow?.show()
    }

    @objc private func menuQuit() {
        pins.closeAll()
        NSApp.terminate(nil)
    }

    // MARK: - Alerts

    func showPermissionAlert() {
        showAlert(
            title: "不能截图",
            message: Permissions.screenRecordingHint,
            settingsPane: "Privacy_ScreenCapture"
        )
    }

    func showAccessibilityAlert() {
        showAlert(
            title: "不能长截图",
            message: Permissions.accessibilityHint,
            settingsPane: "Privacy_Accessibility"
        )
    }

    func showCaptureError(_ error: Error) {
        showAlert(title: "截图失败", message: error.localizedDescription, settingsPane: nil)
    }

    func showRegistrationConflict(_ tags: [HotKeyManager.Tag]) {
        let names = tags.map { Self.name(of: $0) }.joined(separator: "、")
        showAlert(
            title: "快捷键已被占用",
            message: "\(names) 这一组快捷键已被其他程序占用，请换一组。设置没有保存。",
            settingsPane: nil
        )
    }

    private static func name(of tag: HotKeyManager.Tag) -> String {
        switch tag {
        case .capture: return "截图"
        case .paste: return "贴剪切板"
        case .hideAll: return "隐藏全部贴图"
        }
    }

    private func showAlert(title: String, message: String, settingsPane: String?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning

        if settingsPane != nil {
            alert.addButton(withTitle: "打开系统设置…")
            alert.addButton(withTitle: "好")
        } else {
            alert.addButton(withTitle: "好")
        }

        let response = alert.runModal()
        if let pane = settingsPane, response == .alertFirstButtonReturn {
            openSystemSettings(pane)
        }
    }

    private func openSystemSettings(_ pane: String) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - NSMenuDelegate

extension AppEnvironment: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }
}
