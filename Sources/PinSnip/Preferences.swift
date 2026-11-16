import Carbon
import Foundation

/// The two preference items the request asks for: global hotkeys and
/// launch-at-login. Everything else stays at its default.
final class Preferences {

    private enum Key {
        static let capture = "pinsnip.hotkey.capture"
        static let paste = "pinsnip.hotkey.paste"
        static let hideAll = "pinsnip.hotkey.hideAll"
        static let launchAtLogin = "pinsnip.launchAtLogin"
    }

    static let defaultCapture = HotKeyCombo(keyCode: 122, modifiers: 0)          // F1
    static let defaultPaste = HotKeyCombo(keyCode: 99, modifiers: 0)             // F3
    static let defaultHideAll = HotKeyCombo(keyCode: 99, modifiers: UInt32(shiftKey)) // ⇧F3

    var capture: HotKeyCombo {
        get { read(Key.capture, fallback: Self.defaultCapture) }
        set { write(Key.capture, newValue); notifyChange() }
    }

    var paste: HotKeyCombo {
        get { read(Key.paste, fallback: Self.defaultPaste) }
        set { write(Key.paste, newValue); notifyChange() }
    }

    var hideAll: HotKeyCombo {
        get { read(Key.hideAll, fallback: Self.defaultHideAll) }
        set { write(Key.hideAll, newValue); notifyChange() }
    }

    var launchAtLogin: Bool {
        get { UserDefaults.standard.bool(forKey: Key.launchAtLogin) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.launchAtLogin)
            notifyChange()
        }
    }

    /// Called after any value changes so the app can re-register hotkeys.
    var onChange: (() -> Void)?

    private func notifyChange() {
        onChange?()
    }

    private func read(_ key: String, fallback: HotKeyCombo) -> HotKeyCombo {
        guard let array = UserDefaults.standard.array(forKey: key) as? [UInt32], array.count == 2 else {
            return fallback
        }
        return HotKeyCombo(keyCode: array[0], modifiers: array[1])
    }

    private func write(_ key: String, _ combo: HotKeyCombo) {
        UserDefaults.standard.set([combo.keyCode, combo.modifiers], forKey: key)
    }
}
