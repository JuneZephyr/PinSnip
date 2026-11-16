import AppKit

/// A borderless, always-on-top window that never takes keyboard focus, so the
/// user can keep typing in the frontmost application while a pin is visible.
final class PinWindow: NSPanel {

    /// Floating level, not 1000: a pin sits above normal windows but below the
    /// Dock, the menu bar and modal panels, so it never covers a password prompt.
    /// The screensaver and the lock screen live far higher and always win.
    static let windowLevel = NSWindow.Level.floating

    private let imageView = NSImageView()
    private var startPoint: NSPoint = .zero
    private var startFrame: NSRect = .zero
    private var zone: Zone = .move

    var onClose: ((PinWindow) -> Void)?
    var onDestroy: ((PinWindow) -> Void)?
    var onActivate: ((PinWindow) -> Void)?

    init(image: NSImage, globalFrame: NSRect) {
        super.init(
            contentRect: globalFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        level = PinWindow.windowLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isFloatingPanel = true
        contentMinSize = NSSize(width: 40, height: 40)

        imageView.frame = NSRect(origin: .zero, size: globalFrame.size)
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.autoresizingMask = [.width, .height]
        imageView.toolTip = "拖动移动 · 滚轮缩放 · 双击关闭 · 右键更多"
        contentView = imageView
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        onActivate?(self)
        if event.clickCount >= 2 {
            onClose?(self)
            return
        }
        startPoint = NSEvent.mouseLocation
        startFrame = frame
        zone = zone(for: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        let dx = current.x - startPoint.x
        let dy = current.y - startPoint.y

        if !zone.isResize {
            setFrameOrigin(NSPoint(x: startFrame.minX + dx, y: startFrame.minY + dy))
            return
        }

        var next = startFrame
        switch zone {
        case .resizeLeft, .resizeLeftUp, .resizeLeftDown:
            next.origin.x += dx
            next.size.width -= dx
        case .resizeRight, .resizeRightUp, .resizeRightDown:
            next.size.width += dx
        default:
            break
        }
        switch zone {
        case .resizeDown, .resizeLeftDown, .resizeRightDown:
            next.origin.y += dy
            next.size.height -= dy
        case .resizeUp, .resizeLeftUp, .resizeRightUp:
            next.size.height += dy
        default:
            break
        }

        let minimum: CGFloat = 40
        if next.width < minimum {
            if zone.isLeft { next.origin.x = startFrame.maxX - minimum }
            next.size.width = minimum
        }
        if next.height < minimum {
            if zone.isDown { next.origin.y = startFrame.maxY - minimum }
            next.size.height = minimum
        }

        setFrame(next, display: true)
    }

    override func scrollWheel(with event: NSEvent) {
        onActivate?(self)
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        guard delta != 0 else { return }

        var factor = exp(delta * 0.0022)
        factor = min(max(factor, 0.5), 2.0)

        let current = NSEvent.mouseLocation
        let f = frame
        guard f.width > 1, f.height > 1 else { return }

        let ratioX = (current.x - f.minX) / f.width
        let ratioY = (current.y - f.minY) / f.height
        let newSize = NSSize(
            width: max(40, f.width * factor),
            height: max(40, f.height * factor)
        )
        let newOrigin = NSPoint(
            x: current.x - ratioX * newSize.width,
            y: current.y - ratioY * newSize.height
        )
        setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
    }

    override func rightMouseDown(with event: NSEvent) {
        onActivate?(self)
        let menu = NSMenu()
        menu.addItem(self.menuItem(title: "关闭贴图", action: #selector(contextClose)))
        menu.addItem(self.menuItem(title: "销毁贴图", action: #selector(contextDestroy)))
        menu.addItem(.separator())
        menu.addItem(self.menuItem(title: "隐藏全部贴图", action: #selector(contextHideAll)))

        if let view = contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func contextClose() { onClose?(self) }
    @objc private func contextDestroy() { onDestroy?(self) }
    @objc private func contextHideAll() { onActivate?(self); NotificationCenter.default.post(name: .pinHideAllRequested, object: nil) }

    // MARK: - Focus

    /// Pins are non-activating panels: they never become key or main, so the
    /// application behind them keeps the keyboard.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Zones

    private enum Zone: Equatable {
        case move
        case resizeLeft, resizeRight, resizeUp, resizeDown
        case resizeLeftUp, resizeRightUp, resizeLeftDown, resizeRightDown

        var isResize: Bool { self != .move }
        var isLeft: Bool {
            switch self {
            case .resizeLeft, .resizeLeftUp, .resizeLeftDown: return true
            default: return false
            }
        }
        var isDown: Bool {
            switch self {
            case .resizeDown, .resizeLeftDown, .resizeRightDown: return true
            default: return false
            }
        }
    }

    private func zone(for localPoint: NSPoint) -> Zone {
        let f = frame
        let global = NSPoint(x: localPoint.x + f.minX, y: localPoint.y + f.minY)
        let inset: CGFloat = 8

        let left = global.x < f.minX + inset
        let right = global.x > f.maxX - inset
        let down = global.y < f.minY + inset
        let up = global.y > f.maxY - inset

        switch (left, right, down, up) {
        case (true, false, true, false): return .resizeLeftDown
        case (true, false, false, true): return .resizeLeftUp
        case (false, true, true, false): return .resizeRightDown
        case (false, true, false, true): return .resizeRightUp
        case (true, false, false, false): return .resizeLeft
        case (false, true, false, false): return .resizeRight
        case (false, false, true, false): return .resizeDown
        case (false, false, false, true): return .resizeUp
        default: return .move
        }
    }
}

extension Notification.Name {
    static let pinHideAllRequested = Notification.Name("PinSnip.pinHideAllRequested")
}
