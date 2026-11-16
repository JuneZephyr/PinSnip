import ApplicationServices
import CoreGraphics
import Foundation

/// The two permissions this app needs, plus their guidance text.
enum Permissions {

    // MARK: Screen recording (required for every capture)

    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt when the permission is missing.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static var screenRecordingHint: String {
        "不能截图：请前往系统设置 › 隐私与安全性 › 屏幕录制，打开 PinSnip，然后完全退出并重新打开本工具。"
    }

    // MARK: Accessibility (only needed to scroll another app during long capture)

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Checks the newer "event synthesizing" permission used for posting
    /// scroll events, falling back to the classic accessibility check.
    static var canSendScrollEvents: Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightPostEventAccess() || AXIsProcessTrusted()
        }
        return AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static var accessibilityHint: String {
        "不能长截图：请前往系统设置 › 隐私与安全性 › 辅助功能，允许 PinSnip 控制其他应用。普通截图与贴图不受影响。"
    }
}
