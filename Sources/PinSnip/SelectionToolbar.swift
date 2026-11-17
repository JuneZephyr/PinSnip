import AppKit

/// The bar under a finished selection.
/// Tools mode is the icon row from the reference screenshot. Long mode is the
/// auto-scroll bar, and it appears only after 长截图 is clicked.
final class SelectionToolbar: NSPanel {

    enum Direction {
        case vertical
        case horizontal
    }

    static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

    var onCopy: (() -> Void)?
    var onPin: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onLong: (() -> Void)?
    var onTool: ((AnnotateTool) -> Void)?
    var onAutoScroll: (() -> Void)?
    var onManual: (() -> Void)?
    var onDirection: ((Direction) -> Void)?

    private(set) var direction: Direction = .vertical
    private var autoScrollActive = false

    private let chrome = CapsuleChrome()
    private var verticalRadio: RadioControl?
    private var horizontalRadio: RadioControl?
    private var manualRadio: RadioControl?
    private var autoButton: PillButton?
    private var toolButtons: [AnnotateTool: IconButton] = [:]

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = SelectionToolbar.level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // Owned by Swift: closing it must not release it behind our back.
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        appearance = NSAppearance(named: .aqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        contentView = chrome
        showTools()
    }

    /// Icon row: 形状 箭头 画笔 文本 马赛克 钉在桌面 长截图 保存 取消 完成.
    func showTools() {
        chrome.subviews.forEach { $0.removeFromSuperview() }
        verticalRadio = nil
        horizontalRadio = nil
        manualRadio = nil
        autoButton = nil
        toolButtons = [:]

        let height: CGFloat = 52
        chrome.cornerRadius = height / 2
        var x: CGFloat = 14

        let icons: [(AnnotateTool?, IconMark, NSColor, String, (() -> Void)?)] = [
            (.shape, .symbol("square.on.circle"), Palette.label, "形状", { [weak self] in self?.onTool?(.shape) }),
            (.arrow, .symbol("arrow.up.right"), Palette.label, "箭头", { [weak self] in self?.onTool?(.arrow) }),
            (.pen, .symbol("pencil"), Palette.label, "画笔", { [weak self] in self?.onTool?(.pen) }),
            (.text, .letter("A", chevron: true), Palette.label, "文本", { [weak self] in self?.onTool?(.text) }),
            (.mosaic, .mosaic(chevron: true), Palette.label, "马赛克", { [weak self] in self?.onTool?(.mosaic) }),
            (nil, .symbol("pin"), Palette.label, "钉在桌面", { [weak self] in self?.onPin?() }),
            (nil, .symbol("scissors"), Palette.label, "长截图", { [weak self] in self?.onLong?() }),
            (nil, .symbol("square.and.arrow.down"), Palette.label, "保存", { [weak self] in self?.onSave?() }),
            (nil, .symbol("xmark"), Palette.red, "取消", { [weak self] in self?.onCancel?() }),
            (nil, .symbol("checkmark"), Palette.green, "完成", { [weak self] in self?.onCopy?() })
        ]

        for (index, icon) in icons.enumerated() {
            if index == 4 || index == 7 {
                x += 6
                let line = NSView(frame: NSRect(x: x, y: (height - 18) / 2, width: 1, height: 18))
                line.wantsLayer = true
                line.layer?.backgroundColor = Palette.divider.cgColor
                chrome.addSubview(line)
                x += 8
            }
            let button = IconButton(mark: icon.1, tint: icon.2, tip: icon.3)
            button.onClick = icon.4
            if let tool = icon.0 {
                toolButtons[tool] = button
            }
            let width = button.fittingWidth
            button.frame = NSRect(x: x, y: (height - 36) / 2, width: width, height: 36)
            chrome.addSubview(button)
            x += width
        }
        x += 12
        applySize(NSSize(width: x, height: height))
    }

    /// Direction and the auto-scroll button. Shown after 长截图 is clicked.
    func showLongMode() {
        chrome.subviews.forEach { $0.removeFromSuperview() }

        let height: CGFloat = 52
        chrome.cornerRadius = height / 2
        var x: CGFloat = 18

        let promptFont = NSFont.systemFont(ofSize: 13)
        let promptWidth = SelectionToolbar.measured("选择方向", font: promptFont)
        let prompt = NSTextField(labelWithString: "选择方向")
        prompt.font = promptFont
        prompt.textColor = Palette.secondary
        prompt.frame = NSRect(x: x, y: (height - 18) / 2, width: promptWidth, height: 18)
        chrome.addSubview(prompt)
        x += promptWidth + 12

        let vertical = RadioControl(title: "竖向", on: direction == .vertical)
        vertical.onClick = { [weak self] in self?.choose(.vertical) }
        let verticalWidth = vertical.fittingWidth
        vertical.frame = NSRect(x: x, y: (height - 24) / 2, width: verticalWidth, height: 24)
        chrome.addSubview(vertical)
        verticalRadio = vertical
        x += verticalWidth + 14

        let horizontal = RadioControl(title: "横向", on: direction == .horizontal)
        horizontal.onClick = { [weak self] in self?.choose(.horizontal) }
        let horizontalWidth = horizontal.fittingWidth
        horizontal.frame = NSRect(x: x, y: (height - 24) / 2, width: horizontalWidth, height: 24)
        chrome.addSubview(horizontal)
        horizontalRadio = horizontal
        x += horizontalWidth + 16

        let manual = RadioControl(title: "手动", on: !autoScrollActive)
        manual.onClick = { [weak self] in self?.onManual?() }
        let manualWidth = manual.fittingWidth
        manual.frame = NSRect(x: x, y: (height - 24) / 2, width: manualWidth, height: 24)
        chrome.addSubview(manual)
        manualRadio = manual
        x += manualWidth + 14

        let pillFont = NSFont.systemFont(ofSize: 14, weight: .medium)
        let pillWidth = max(
            SelectionToolbar.measured("自动滚动", font: pillFont),
            SelectionToolbar.measured("滚动中", font: pillFont)
        ) + 36
        let pill = PillButton(title: autoScrollActive ? "滚动中" : "自动滚动")
        pill.isRunning = autoScrollActive
        pill.onClick = { [weak self] in self?.onAutoScroll?() }
        pill.frame = NSRect(x: x, y: (height - 32) / 2, width: pillWidth, height: 32)
        chrome.addSubview(pill)
        autoButton = pill
        x += pillWidth + 14

        let line = NSView(frame: NSRect(x: x, y: (height - 22) / 2, width: 1, height: 22))
        line.wantsLayer = true
        line.layer?.backgroundColor = Palette.divider.cgColor
        chrome.addSubview(line)
        x += 10

        let icons: [(String, NSColor, String, () -> Void)] = [
            ("pin", Palette.label, "钉在桌面", { [weak self] in self?.onPin?() }),
            ("square.and.arrow.down", Palette.label, "保存", { [weak self] in self?.onSave?() }),
            ("xmark", Palette.red, "取消", { [weak self] in self?.onCancel?() }),
            ("checkmark", Palette.green, "完成", { [weak self] in self?.onCopy?() })
        ]
        for icon in icons {
            let button = IconButton(symbol: icon.0, tint: icon.1, tip: icon.2)
            button.onClick = icon.3
            button.frame = NSRect(x: x, y: (height - 36) / 2, width: 36, height: 36)
            chrome.addSubview(button)
            x += 36
        }
        x += 12
        applySize(NSSize(width: x, height: height))
    }

    private func applySize(_ size: NSSize) {
        chrome.frame = NSRect(origin: .zero, size: size)
        chrome.needsDisplay = true
        setContentSize(size)
    }

    func setActiveTool(_ tool: AnnotateTool?) {
        for (candidate, button) in toolButtons {
            button.isOn = candidate == tool
        }
    }

    /// The tool button's frame in screen coordinates, used to anchor its option bar.
    func buttonScreenFrame(_ tool: AnnotateTool) -> NSRect? {
        guard let button = toolButtons[tool] else { return nil }
        let inWindow = button.convert(button.bounds, to: nil)
        return convertToScreen(inWindow)
    }

    func setAutoScrollActive(_ active: Bool) {
        autoScrollActive = active
        autoButton?.title = active ? "滚动中" : "自动滚动"
        autoButton?.isRunning = active
        autoButton?.needsDisplay = true
        // The manual/auto switch is only meaningful while the direction is
        // vertical: horizontal long captures are watch-only, so the auto pill
        // never runs and claiming "手动" would be misleading.
        manualRadio?.isOn = !active && direction == .vertical
    }

    private func choose(_ direction: Direction) {
        guard !autoScrollActive, self.direction != direction else { return }
        self.direction = direction
        verticalRadio?.isOn = direction == .vertical
        horizontalRadio?.isOn = direction == .horizontal
        manualRadio?.isOn = direction == .vertical
        onDirection?(direction)
    }

    private static func measured(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

// MARK: - Chrome

enum Palette {
    static let label = NSColor(srgbRed: 0.20, green: 0.22, blue: 0.26, alpha: 1)
    static let secondary = NSColor(srgbRed: 0.45, green: 0.48, blue: 0.53, alpha: 1)
    static let divider = NSColor(srgbRed: 0.84, green: 0.85, blue: 0.87, alpha: 1)
    static let red = NSColor(srgbRed: 0.95, green: 0.27, blue: 0.23, alpha: 1)
    static let green = NSColor(srgbRed: 0.16, green: 0.74, blue: 0.32, alpha: 1)
    static let blue = NSColor(srgbRed: 0.18, green: 0.48, blue: 0.98, alpha: 1)
}

final class CapsuleChrome: NSView {
    var cornerRadius: CGFloat = 8

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        if NSApp.activationPolicy() == .regular {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(cornerRadius, rect.height / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.white.setFill()
        path.fill()
        NSColor(white: 0, alpha: 0.08).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private final class RadioControl: NSView {
    var title: String
    var isOn: Bool {
        didSet { needsDisplay = true }
    }
    var onClick: (() -> Void)?

    private let font = NSFont.systemFont(ofSize: 13)

    init(title: String, on: Bool) {
        self.title = title
        self.isOn = on
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var fittingWidth: CGFloat {
        16 + 6 + ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }

    override func draw(_ dirtyRect: NSRect) {
        let circleRect = NSRect(x: 0.5, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let circle = NSBezierPath(ovalIn: circleRect)
        if isOn {
            Palette.blue.setFill()
            circle.fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: circleRect.insetBy(dx: 4, dy: 4)).fill()
        } else {
            NSColor(calibratedWhite: 0.74, alpha: 1).setStroke()
            circle.lineWidth = 1.4
            circle.stroke()
        }

        let text = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: Palette.label
        ])
        let size = text.size()
        let rect = NSRect(x: 22, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        text.draw(in: rect)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }
}

private final class PillButton: NSView {
    var title: String
    var isRunning = false {
        didSet { needsDisplay = true }
    }
    var onClick: (() -> Void)?

    private let font = NSFont.systemFont(ofSize: 14, weight: .medium)

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (isRunning ? Palette.blue.withAlphaComponent(0.85) : Palette.blue).setFill()
        path.fill()

        let text = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: NSColor.white
        ])
        let size = text.size()
        let rect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        text.draw(in: rect)
    }

    override func mouseDown(with event: NSEvent) {
        alphaValue = 0.82
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }
}

enum IconMark {
    case symbol(String)
    case letter(String, chevron: Bool)
    case mosaic(chevron: Bool)
}

final class IconButton: NSView {
    var onClick: (() -> Void)?
    var isOn = false {
        didSet { needsDisplay = true }
    }

    private let mark: IconMark
    private let tint: NSColor

    init(mark: IconMark, tint: NSColor, tip: String) {
        self.mark = mark
        self.tint = tint
        super.init(frame: .zero)
        toolTip = tip
    }

    convenience init(symbol: String, tint: NSColor, tip: String) {
        self.init(mark: .symbol(symbol), tint: tint, tip: tip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var fittingWidth: CGFloat {
        switch mark {
        case .symbol: return 34
        case .letter(_, let chevron): return chevron ? 40 : 30
        case .mosaic(let chevron): return chevron ? 42 : 30
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isOn {
            let highlight = bounds.insetBy(dx: 1, dy: 5)
            NSColor(white: 0.93, alpha: 1).setFill()
            NSBezierPath(roundedRect: highlight, xRadius: 7, yRadius: 7).fill()
        }
        switch mark {
        case .symbol(let name):
            drawSymbol(name, side: 17, at: NSPoint(x: (bounds.width - 17) / 2, y: (bounds.height - 17) / 2))
        case .letter(let text, let chevron):
            drawLetter(text, chevron: chevron)
        case .mosaic(let chevron):
            drawMosaic(chevron: chevron)
        }
    }

    private func drawLetter(_ text: String, chevron: Bool) {
        let font = NSFont.systemFont(ofSize: 16, weight: .medium)
        let string = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: tint
        ])
        let size = string.size()
        let chevronWidth: CGFloat = chevron ? 10 : 0
        let originX = (bounds.width - size.width - chevronWidth) / 2
        string.draw(in: NSRect(x: originX, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        if chevron {
            drawSymbol("chevron.down", side: 8, at: NSPoint(x: originX + size.width + 2, y: (bounds.height - 8) / 2))
        }
    }

    private func drawMosaic(chevron: Bool) {
        let side: CGFloat = 14
        let chevronWidth: CGFloat = chevron ? 10 : 0
        let origin = NSPoint(
            x: (bounds.width - side - chevronWidth) / 2,
            y: (bounds.height - side) / 2
        )
        let cell = side / 2
        let cells: [(NSRect, NSColor)] = [
            (NSRect(x: origin.x, y: origin.y + cell, width: cell, height: cell), tint),
            (NSRect(x: origin.x + cell, y: origin.y + cell, width: cell, height: cell), .white),
            (NSRect(x: origin.x, y: origin.y, width: cell, height: cell), .white),
            (NSRect(x: origin.x + cell, y: origin.y, width: cell, height: cell), tint)
        ]
        for (rect, color) in cells {
            color.setFill()
            NSBezierPath(rect: rect).fill()
        }
        tint.setStroke()
        let border = NSBezierPath(rect: NSRect(x: origin.x + 0.5, y: origin.y + 0.5, width: side - 1, height: side - 1))
        border.lineWidth = 1
        border.stroke()
        if chevron {
            drawSymbol("chevron.down", side: 8, at: NSPoint(x: origin.x + side + 3, y: (bounds.height - 8) / 2))
        }
    }

    private func drawSymbol(_ name: String, side: CGFloat, at origin: NSPoint) {
        let base = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
        let colored = base.applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(colored) else { return }
        image.draw(
            in: NSRect(x: origin.x, y: origin.y, width: side, height: side),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }

    override func mouseDown(with event: NSEvent) {
        alphaValue = 0.55
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }
}
