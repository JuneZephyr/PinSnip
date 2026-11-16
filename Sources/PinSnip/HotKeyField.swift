import AppKit
import Carbon

/// A read-only text field that records the next key combination.
final class HotKeyField: NSTextField {

    var combo: HotKeyCombo? {
        didSet { stringValue = combo?.displayName ?? "点击后按下快捷键" }
    }

    var onRecord: ((HotKeyCombo) -> Void)?

    private var recording = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = false
        isSelectable = false
        isBordered = true
        alignment = .center
        font = NSFont.systemFont(ofSize: 13)
        stringValue = "点击后按下快捷键"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        recording = true
        stringValue = "按下快捷键…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        recording = false
        let recorded = HotKeyCombo(keyCode: UInt32(event.keyCode),
                                   modifiers: carbonModifiers(event.modifierFlags))
        combo = recorded
        onRecord?(recorded)
    }

    override func flagsChanged(with event: NSEvent) {
        guard recording else { return }
        var text = ""
        let modifiers = event.modifierFlags
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        stringValue = text.isEmpty ? "按下快捷键…" : text
    }
}

extension NSEvent.ModifierFlags {
    /// Carbon modifier bits, which is what the system hotkey API expects.
    var carbon: UInt32 {
        var result: UInt32 = 0
        if contains(.command) { result |= UInt32(cmdKey) }
        if contains(.shift) { result |= UInt32(shiftKey) }
        if contains(.option) { result |= UInt32(optionKey) }
        if contains(.control) { result |= UInt32(controlKey) }
        if contains(.capsLock) { result |= UInt32(alphaLock) }
        return result
    }
}

func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    flags.carbon
}
