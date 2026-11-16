import AppKit

/// Side preview of the growing long screenshot. Never part of the final image.
final class PreviewPanel: NSPanel {

    static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = PreviewPanel.level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]

        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor(white: 1, alpha: 0.3).cgColor

        contentView = NSView()
        contentView?.addSubview(imageView)
        contentView?.addSubview(label)
    }

    func update(image: CGImage, pixelHeight: Int, maxScreenHeight: CGFloat, caption: String? = nil) {
        let aspect = CGFloat(image.height) / max(1, CGFloat(image.width))

        var width: CGFloat = 170
        var height = width * aspect
        if height > maxScreenHeight {
            let fit = maxScreenHeight / height
            width *= fit
            height = maxScreenHeight
        }
        height = min(height, maxScreenHeight)

        let labelHeight: CGFloat = 22
        let contentWidth = max(60, width)
        let contentHeight = height + labelHeight

        setContentSize(NSSize(width: contentWidth, height: contentHeight))
        imageView.frame = NSRect(x: 0, y: labelHeight, width: contentWidth, height: height)
        label.frame = NSRect(x: 0, y: 0, width: contentWidth, height: labelHeight)
        imageView.image = NSImage(cgImage: image, size: NSSize(width: contentWidth, height: height))
        label.stringValue = caption ?? "已拼接 \(pixelHeight) px"
    }
}
