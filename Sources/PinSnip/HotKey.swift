import AppKit
import Carbon
import Foundation

/// A global hotkey: a virtual key code plus Carbon modifier flags.
struct HotKeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(keyCode: Int, modifiers: UInt32) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = modifiers
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(alphaLock) != 0 { flags.insert(.capsLock) }
        return flags
    }

    /// Human readable label, e.g. "F1", "⇧F3", "⌘T".
    var displayName: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        if modifiers & UInt32(alphaLock) != 0 { text += "⇪" }
        text += HotKeyLabels.name(forKeyCode: keyCode)
        return text
    }
}

enum HotKeyLabels {
    static func name(forKeyCode keyCode: UInt32) -> String {
        if let special = specialNames[keyCode] { return special }
        if let scalar = ansiCharacters[keyCode] {
            return String(Character(UnicodeScalar(scalar))).uppercased()
        }
        return "键 \(keyCode)"
    }

    private static let specialNames: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        36: "↩", 76: "⌤", 53: "esc", 48: "⇥", 49: "空格",
        51: "⌫", 117: "⌦", 115: "⇤", 123: "←", 124: "→",
        125: "↓", 126: "↑", 116: "⇞", 121: "⇟", 119: "↘",
        114: "⇱", 35: "PrtSc", 71: "Clear", 75: "⌿", 67: "✳",
        69: "+", 78: "−", 81: "=", 91: "−", 92: "＋"
    ]

    private static let ansiCharacters: [UInt32: Unicode.Scalar] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 32: "u", 34: "i", 31: "o", 35: "p", 37: "l",
        38: "j", 40: "k", 45: "n", 46: "m", 18: "1", 19: "2", 20: "3",
        21: "4", 22: "5", 23: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        27: "-", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'",
        44: "/", 43: ",", 47: ".", 50: "`"
    ]
}
