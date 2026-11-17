import AppKit

/// The white option capsule that hangs off the selected tool.
final class ToolOptionsBar: NSPanel {

    var style = AnnotateStyle()
    var onChange: (() -> Void)?
    var onGestureBegin: (() -> Void)?
    var onGestureEnd: (() -> Void)?
    var onAutoMosaic: (() -> Void)?
    var onClearMosaic: (() -> Void)?

    private let chrome = CapsuleChrome()
    private let caret = CaretView()
    private var colorPick: ((NSColor?) -> Void)?
    private var sliderBoxes: [SliderBox] = []

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = SelectionToolbar.level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        appearance = NSAppearance(named: .aqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]

        let root = NSView(frame: contentRect(forFrameRect: frame))
        root.wantsLayer = true
        contentView = root
        root.addSubview(chrome)
        root.addSubview(caret)
    }

    func reload(tool: AnnotateTool) {
        chrome.subviews.forEach { $0.removeFromSuperview() }
        sliderBoxes.removeAll()
        let height: CGFloat = 40
        chrome.cornerRadius = height / 2
        var x: CGFloat = 10

        switch tool {
        case .shape:
            x = addShapeChoices(x: x, height: height)
        case .arrow, .pen:
            x = addWidthAndColor(title: "粗细", value: style.lineWidth, range: 1...20, x: x, height: height) { [weak self] value in
                self?.style.lineWidth = value
                self?.onChange?()
            }
        case .text:
            x = addTextChoices(x: x, height: height)
        case .mosaic:
            x = addMosaicChoices(x: x, height: height)
        }

        x += 8
        chrome.frame = NSRect(x: 0, y: 0, width: x, height: height)
        let size = NSSize(width: x, height: height + 8)
        contentView?.setFrameSize(size)
        setContentSize(size)
        placeCaret(x: size.width / 2, pointingUp: true)
    }

    func placeCaret(x: CGFloat, pointingUp: Bool) {
        guard let root = contentView else { return }
        let height = chrome.frame.height
        caret.pointingUp = pointingUp
        caret.frame = NSRect(x: min(max(4, x - 6), root.bounds.width - 16), y: pointingUp ? height - 1 : 0, width: 12, height: 8)
        chrome.setFrameOrigin(NSPoint(x: 0, y: pointingUp ? 0 : 8))
        caret.needsDisplay = true
    }

    // MARK: - Rows

    private func addShapeChoices(x start: CGFloat, height: CGFloat) -> CGFloat {
        var x = start
        let shapes: [(ShapeKind, IconMark, String)] = [
            (.rectangle, .symbol("rectangle"), "矩形"),
            (.oval, .symbol("circle"), "椭圆"),
            (.line, .symbol("line.diagonal"), "直线")
        ]
        for item in shapes {
            let button = optionIcon(item.1, tip: item.2, on: style.shapeKind == item.0)
            button.onClick = { [weak self] in
                self?.style.shapeKind = item.0
                self?.reload(tool: .shape)
                self?.onChange?()
            }
            place(button, x: x, height: height, width: 32)
            x += 32
        }
        x = addDivider(x: x, height: height)
        let stroke = optionIcon(.symbol("circle"), tip: "描边", on: !style.filled)
        stroke.onClick = { [weak self] in
            self?.style.filled = false
            self?.reload(tool: .shape)
            self?.onChange?()
        }
        place(stroke, x: x, height: height, width: 32)
        x += 32
        let fill = optionIcon(.symbol("square.fill"), tip: "填充", on: style.filled)
        fill.onClick = { [weak self] in
            self?.style.filled = true
            self?.reload(tool: .shape)
            self?.onChange?()
        }
        place(fill, x: x, height: height, width: 32)
        x += 32
        x = addDivider(x: x, height: height)
        return addWidthAndColor(title: "粗细", value: style.lineWidth, range: 1...20, x: x, height: height) { [weak self] value in
            self?.style.lineWidth = value
            self?.onChange?()
        }
    }

    private func addTextChoices(x start: CGFloat, height: CGFloat) -> CGFloat {
        var x = start
        let colorButton = TextStyleButton(title: "A", color: style.color, filled: false)
        colorButton.onClick = { [weak self] in
            guard let self else { return }
            self.popColors(from: colorButton, includeClear: false) { color in
                guard let color else { return }
                self.style.color = color
                self.reload(tool: .text)
                self.onChange?()
            }
        }
        place(colorButton, x: x, height: height, width: 36)
        x += 38
        let background = TextStyleButton(title: "A", color: style.textBackground ?? Palette.secondary, filled: style.textBackground != nil)
        background.onClick = { [weak self] in
            guard let self else { return }
            self.popColors(from: background, includeClear: true) { color in
                self.style.textBackground = color
                self.reload(tool: .text)
                self.onChange?()
            }
        }
        place(background, x: x, height: height, width: 36)
        x += 36
        x = addDivider(x: x, height: height)
        return addSlider(title: "大小", value: style.textSize, range: 12...96, x: x, height: height) { [weak self] value in
            self?.style.textSize = value
            self?.onChange?()
        }
    }

    private func addMosaicChoices(x start: CGFloat, height: CGFloat) -> CGFloat {
        var x = start
        x = addModeButton("手动", on: style.mosaicManual, x: x, height: height) { [weak self] in
            self?.style.mosaicManual = true
            self?.reload(tool: .mosaic)
        }
        x = addModeButton("自动", on: !style.mosaicManual, x: x, height: height) { [weak self] in
            self?.style.mosaicManual = false
            self?.reload(tool: .mosaic)
            self?.onAutoMosaic?()
        }
        x = addDivider(x: x, height: height)
        let pixelate = optionIcon(.mosaic(chevron: false), tip: "像素", on: !style.mosaicBlur)
        pixelate.onClick = { [weak self] in
            self?.style.mosaicBlur = false
            self?.reload(tool: .mosaic)
        }
        place(pixelate, x: x, height: height, width: 34)
        x += 34
        let blur = optionIcon(.symbol("drop"), tip: "模糊", on: style.mosaicBlur)
        blur.onClick = { [weak self] in
            self?.style.mosaicBlur = true
            self?.reload(tool: .mosaic)
        }
        place(blur, x: x, height: height, width: 32)
        x += 32
        x = addDivider(x: x, height: height)
        let brush = optionIcon(.symbol("hand.point.up.left"), tip: "涂抹", on: style.mosaicBrush)
        brush.onClick = { [weak self] in
            self?.style.mosaicBrush = true
            self?.style.mosaicManual = true
            self?.reload(tool: .mosaic)
        }
        place(brush, x: x, height: height, width: 32)
        x += 32
        let box = optionIcon(.symbol("arrow.up.and.down.and.arrow.left.and.right"), tip: "框选", on: !style.mosaicBrush)
        box.onClick = { [weak self] in
            self?.style.mosaicBrush = false
            self?.style.mosaicManual = true
            self?.reload(tool: .mosaic)
        }
        place(box, x: x, height: height, width: 34)
        x += 34
        x = addDivider(x: x, height: height)
        x = addSlider(title: "像素", value: style.mosaicPixel, range: 2...30, x: x, height: height) { [weak self] value in
            self?.style.mosaicPixel = value
            self?.onChange?()
        }
        let clear = NSButton(title: "清除", target: nil, action: nil)
        clear.isBordered = false
        clear.font = NSFont.systemFont(ofSize: 12)
        clear.wantsLayer = true
        clear.layer?.cornerRadius = 6
        clear.layer?.borderWidth = 1
        clear.layer?.borderColor = Palette.divider.cgColor
        clear.target = self
        clear.action = #selector(clearMosaics)
        place(clear, x: x, height: height, width: 52)
        return x + 52
    }

    private func addWidthAndColor(title: String, value: CGFloat, range: ClosedRange<CGFloat>, x: CGFloat, height: CGFloat, changed: @escaping (CGFloat) -> Void) -> CGFloat {
        var next = addSlider(title: title, value: value, range: range, x: x, height: height, changed: changed)
        let swatch = ColorSwatch(color: style.color)
        swatch.onClick = { [weak self] in
            guard let self else { return }
            self.popColors(from: swatch, includeClear: false) { color in
                guard let color else { return }
                self.style.color = color
                swatch.color = color
                self.onChange?()
            }
        }
        place(swatch, x: next, height: height, width: 28)
        next += 28
        return next
    }

    private func addSlider(title: String, value: CGFloat, range: ClosedRange<CGFloat>, x start: CGFloat, height: CGFloat, changed: @escaping (CGFloat) -> Void) -> CGFloat {
        var x = start
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = Palette.label
        let labelWidth = ceil((title as NSString).size(withAttributes: [.font: label.font!]).width)
        place(label, x: x, height: height, width: labelWidth)
        x += labelWidth + 6

        let slider = NSSlider(value: Double(value), minValue: Double(range.lowerBound), maxValue: Double(range.upperBound), target: nil, action: nil)
        slider.isContinuous = true
        let number = NSTextField(labelWithString: "\(Int(value.rounded()))")
        number.font = NSFont.systemFont(ofSize: 12)
        number.textColor = Palette.secondary
        number.alignment = .left
        let box = SliderBox(valueLabel: number, changed: changed)
        box.onBegin = { [weak self] in self?.onGestureBegin?() }
        box.onEnd = { [weak self] in self?.onGestureEnd?() }
        sliderBoxes.append(box)
        slider.target = box
        slider.action = #selector(SliderBox.moved(_:))
        place(slider, x: x, height: height, width: 88)
        x += 92
        place(number, x: x, height: height, width: 24)
        x += 28
        return x
    }

    private func addModeButton(_ title: String, on: Bool, x: CGFloat, height: CGFloat, action: @escaping () -> Void) -> CGFloat {
        let width = title.count > 2 ? 52 : 44
        let button = ModeButton(title: title, on: on)
        button.onClick = action
        place(button, x: x, height: height, width: CGFloat(width))
        return x + CGFloat(width)
    }

    private func addDivider(x: CGFloat, height: CGFloat) -> CGFloat {
        let line = NSView(frame: .zero)
        line.wantsLayer = true
        line.layer?.backgroundColor = Palette.divider.cgColor
        place(line, x: x + 4, height: height, width: 1, customHeight: 16)
        return x + 12
    }

    private func optionIcon(_ mark: IconMark, tip: String, on: Bool) -> IconButton {
        let button = IconButton(mark: mark, tint: Palette.label, tip: tip)
        button.isOn = on
        return button
    }

    private func place(_ view: NSView, x: CGFloat, height: CGFloat, width: CGFloat, customHeight: CGFloat? = nil) {
        let itemHeight = customHeight ?? min(28, height - 8)
        view.frame = NSRect(x: x, y: (height - itemHeight) / 2, width: width, height: itemHeight)
        chrome.addSubview(view)
    }

    @objc private func clearMosaics() {
        onClearMosaic?()
    }

    private func popColors(from view: NSView, includeClear: Bool, pick: @escaping (NSColor?) -> Void) {
        colorPick = pick
        let menu = NSMenu()
        if includeClear {
            let clear = NSMenuItem(title: "无背景", action: #selector(pickedClear), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
        for color in AnnotateStyle.palette {
            let item = NSMenuItem(title: "", action: #selector(pickedColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color
            item.image = ColorSwatch.image(color, size: 14)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
    }

    @objc private func pickedClear() {
        colorPick?(nil)
    }

    @objc private func pickedColor(_ sender: NSMenuItem) {
        colorPick?(sender.representedObject as? NSColor)
    }
}

private final class SliderBox: NSObject {
    let valueLabel: NSTextField
    let changed: (CGFloat) -> Void
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    private var open = false

    init(valueLabel: NSTextField, changed: @escaping (CGFloat) -> Void) {
        self.valueLabel = valueLabel
        self.changed = changed
    }

    /// A drag is one undo step. Mouse-down records the mark, mouse-up closes it.
    @objc func moved(_ sender: NSSlider) {
        let type = NSApp.currentEvent?.type
        if !open, type != .leftMouseUp {
            open = true
            onBegin?()
        }
        let value = CGFloat(sender.doubleValue)
        valueLabel.stringValue = "\(Int(value.rounded()))"
        changed(value)
        if type == .leftMouseUp {
            open = false
            onEnd?()
        }
    }
}

private final class CaretView: NSView {
    var pointingUp = true {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        if pointingUp {
            path.move(to: NSPoint(x: bounds.midX, y: bounds.maxY))
            path.line(to: NSPoint(x: bounds.minX, y: bounds.minY))
            path.line(to: NSPoint(x: bounds.maxX, y: bounds.minY))
        } else {
            path.move(to: NSPoint(x: bounds.midX, y: bounds.minY))
            path.line(to: NSPoint(x: bounds.minX, y: bounds.maxY))
            path.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY))
        }
        path.close()
        NSColor.white.setFill()
        path.fill()
    }
}

private final class ModeButton: NSView {
    var onClick: (() -> Void)?
    private let title: String
    private let on: Bool

    init(title: String, on: Bool) {
        self.title = title
        self.on = on
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        if on {
            NSColor(white: 0.93, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: on ? .medium : .regular),
            .foregroundColor: Palette.label
        ])
        let size = text.size()
        text.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }
}

private final class ColorSwatch: NSView {
    var color: NSColor {
        didSet { needsDisplay = true }
    }
    var onClick: (() -> Void)?

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        color.setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        Palette.divider.setStroke()
        let border = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        border.lineWidth = 1
        border.stroke()
        Self.chevron.draw(in: NSRect(x: box.maxX + 2, y: (bounds.height - 8) / 2, width: 8, height: 8))
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    static func image(_ color: NSColor, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: 2, yRadius: 2).fill()
        image.unlockFocus()
        return image
    }

    private static let chevron: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        let tint = config.applying(NSImage.SymbolConfiguration(paletteColors: [Palette.secondary]))
        return NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(tint) ?? NSImage()
    }()
}

private final class TextStyleButton: NSView {
    var onClick: (() -> Void)?
    private let title: String
    private let color: NSColor
    private let filled: Bool

    init(title: String, color: NSColor, filled: Bool) {
        self.title = title
        self.color = color
        self.filled = filled
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        if filled {
            color.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 6), xRadius: 4, yRadius: 4).fill()
        }
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: Palette.label,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: color
        ])
        let size = text.size()
        text.draw(in: NSRect(x: 4, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)) {
            chevron.draw(in: NSRect(x: bounds.maxX - 12, y: (bounds.height - 8) / 2, width: 8, height: 8))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }
}
