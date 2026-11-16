import AppKit
import CoreGraphics

/// Owns every pin window and the in-memory "recently closed" slot.
/// Nothing is written to disk: quitting the app drops all pins.
final class PinManager {

    private(set) var pins: [PinWindow] = []
    private(set) var activePin: PinWindow?
    private var lastClosed: PinWindow?
    private var lastClipboardStamp: String?
    private var cascadeIndex = 0
    private var hidden = false

    var onHideAllRequested: (() -> Void)?

    // MARK: Creating

    @discardableResult
    func pinImage(_ image: NSImage,
                  pointSize: NSSize? = nil,
                  centeredAt center: NSPoint? = nil) -> PinWindow {
        // Never larger than one screen: a long screenshot is pinned as a strip
        // that fits the display, and the wheel zoom enlarges it from there.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let limits = screen.frame.size
        var size = pointSize ?? image.size
        if size.width > limits.width || size.height > limits.height {
            let fit = min(limits.width / max(1, size.width), limits.height / max(1, size.height))
            size = NSSize(width: max(40, size.width * fit), height: max(40, size.height * fit))
        }
        size.width = max(40, size.width)
        size.height = max(40, size.height)

        let origin: NSPoint
        if let center {
            origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        } else {
            cascadeIndex = (cascadeIndex + 1) % 10
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let visible = screen.visibleFrame
            let dx = CGFloat(cascadeIndex % 5) * 28 - 56
            let dy = CGFloat(cascadeIndex / 5) * 28 - 28
            origin = NSPoint(
                x: visible.midX + dx - size.width / 2,
                y: visible.midY + dy - size.height / 2
            )
        }

        let window = PinWindow(image: image, globalFrame: NSRect(origin: origin, size: size))
        window.onClose = { [weak self] pin in self?.close(pin) }
        window.onDestroy = { [weak self] pin in self?.destroy(pin) }
        window.onActivate = { [weak self] pin in self?.activePin = pin }

        pins.append(window)
        activePin = window
        hidden = false
        window.orderFrontRegardless()
        return window
    }

    // MARK: Closing and destroying

    func close(_ pin: PinWindow) {
        guard let index = pins.firstIndex(of: pin) else { return }
        pins.remove(at: index)
        if activePin === pin { activePin = nil }
        lastClosed = pin
        pin.orderOut(nil)
    }

    func destroy(_ pin: PinWindow) {
        if let index = pins.firstIndex(of: pin) {
            pins.remove(at: index)
        }
        if lastClosed === pin { lastClosed = nil }
        if activePin === pin { activePin = nil }
        pin.orderOut(nil)
        pin.close()
    }

    /// The single pin that the paste hotkey brings back.
    func restoreLastClosed() {
        guard let pin = lastClosed else { return }
        lastClosed = nil
        if !pins.contains(pin) {
            pins.append(pin)
        }
        hidden = false
        pin.orderFrontRegardless()
        activePin = pin
    }

    // MARK: - Closing keys

    private var keyMonitor: Any?

    /// Watches Esc, Cmd-W and Shift-Esc without registering them as system-wide
    /// hotkeys.
    ///
    /// A registered hotkey swallows the key for every application and for system
    /// dialogs, which is exactly what must not happen. A global monitor only
    /// observes the keystroke - it still reaches whatever is frontmost - and it
    /// acts only while the pointer is over a pin.
    func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            DispatchQueue.main.async { self?.handleKeyEvent(event) }
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let isEscape = event.keyCode == 53
        let isClose = isEscape || (event.keyCode == 13 && event.modifierFlags.contains(.command))
        guard isEscape || isClose else { return }

        guard let pin = pinAt(NSEvent.mouseLocation) else { return }
        if isEscape && event.modifierFlags.contains(.shift) {
            destroy(pin)
        } else {
            close(pin)
        }
    }

    /// The topmost pin whose window sits under a Cocoa-screen point.
    private func pinAt(_ point: NSPoint) -> PinWindow? {
        pins.last { $0.frame.contains(point) }
    }

    // MARK: Hide and show

    func hideAll() {
        guard !pins.isEmpty else { return }
        hidden = true
        for pin in pins { pin.orderOut(nil) }
    }

    func showAll() {
        guard !pins.isEmpty else { return }
        hidden = false
        for pin in pins { pin.orderFrontRegardless() }
    }

    func toggleHideAll() {
        if hidden {
            showAll()
        } else {
            hideAll()
        }
    }

    // MARK: Clipboard

    func pasteClipboard() {
        guard let content = ClipboardContent.read() else { return }

        if let stamp = lastClipboardStamp, stamp == content.stamp {
            // Same clipboard entry as last time: bring the closed pin back
            // instead of stacking an identical copy on screen.
            restoreLastClosed()
            return
        }
        lastClipboardStamp = content.stamp

        switch content.kind {
        case .image(let image):
            pinImage(image, pointSize: image.size)
        case .text(let text):
            let card = TextCard.render(text)
            pinImage(card, pointSize: card.size)
        }
    }

    // MARK: Cleanup

    func closeAll() {
        for pin in pins { pin.orderOut(nil) }
        pins.removeAll()
        lastClosed = nil
        activePin = nil
    }

    func allWindowIDs() -> [CGWindowID] {
        pins.compactMap { pin -> CGWindowID? in
            let number = pin.windowNumber
            return number > 0 ? CGWindowID(number) : nil
        }
    }
}
