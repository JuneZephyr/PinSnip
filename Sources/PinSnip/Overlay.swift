import AppKit

/// Full-screen, borderless, key window that freezes one captured display and
/// collects the drag that defines the region.
final class OverlayWindow: NSWindow {

    /// Above normal windows, below the menu bar and the Dock. Covering the
    /// menu bar from a menu-bar app swallows every click and leaves no way out.
    static let level = NSWindow.Level.floating

    weak var controller: SelectionController?

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        level = OverlayWindow.level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        controller?.handleKeyDown(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.cancel()
    }
}

// MARK: - View

protocol OverlayViewDelegate: AnyObject {
    func overlayMouseDown(_ view: OverlayView, globalPoint: NSPoint)
    func overlayMouseDragged(_ view: OverlayView, globalPoint: NSPoint)
    func overlayMouseUp(_ view: OverlayView, globalPoint: NSPoint)
    func overlayMouseMoved(_ view: OverlayView, globalPoint: NSPoint)
    func overlayDoubleClicked(_ view: OverlayView, globalPoint: NSPoint)
    func overlayRightClicked(_ view: OverlayView)
}

final class OverlayView: NSView {

    weak var delegate: OverlayViewDelegate?

    /// Frozen display contents, in pixels.
    var snapshot: CGImage? {
        didSet { snapshotImage = snapshot.map { NSImage(cgImage: $0, size: bounds.size) } }
    }
    private var snapshotImage: NSImage?

    /// Selection in this window's coordinate space.
    var selection: NSRect = .zero
    var hasSelection: Bool = false
    var dimAlpha: CGFloat = 0.35
    var label: String = ""
    var annotationMarks: [AnnotationMark] = []
    var annotationDraft: AnnotationMark?
    var annotationPixels: PixelBuffer?

    private let handleSize: CGFloat = 7

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let live = snapshotImage == nil
        if let snapshotImage {
            snapshotImage.draw(in: bounds)

            let dim = NSBezierPath(rect: bounds)
            if hasSelection && !selection.isEmpty {
                dim.append(NSBezierPath(rect: selection))
            }
            dim.windingRule = .evenOdd
            NSColor(white: 0, alpha: dimAlpha).setFill()
            dim.fill()
        }

        if hasSelection, !selection.isEmpty {
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            for mark in annotationMarks {
                mark.draw(pixels: annotationPixels)
            }
            annotationDraft?.draw(pixels: annotationPixels)
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        guard hasSelection, !selection.isEmpty else {
            if !live, !label.isEmpty { drawHint() }
            return
        }

        // Stroke only outside the selection. A line drawn on the inside edge is
        // captured with every frame and shows up as a blue stripe at each join.
        NSGraphicsContext.current?.saveGraphicsState()
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: selection))
        outside.windingRule = .evenOdd
        outside.addClip()
        let border = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
        NSColor.systemBlue.setStroke()
        border.lineWidth = 2
        border.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()

        if !live {
            drawHandles()
        }
        if !label.isEmpty {
            drawLabel()
        }
    }

    private func drawHandles() {
        NSColor.systemBlue.setFill()
        NSColor.white.setStroke()
        let half = handleSize / 2
        let points: [NSPoint] = [
            NSPoint(x: selection.minX, y: selection.minY),
            NSPoint(x: selection.midX, y: selection.minY),
            NSPoint(x: selection.maxX, y: selection.minY),
            NSPoint(x: selection.minX, y: selection.midY),
            NSPoint(x: selection.maxX, y: selection.midY),
            NSPoint(x: selection.minX, y: selection.maxY),
            NSPoint(x: selection.midX, y: selection.maxY),
            NSPoint(x: selection.maxX, y: selection.maxY)
        ]
        for point in points {
            let rect = NSRect(x: point.x - half, y: point.y - half, width: handleSize, height: handleSize)
            let path = NSBezierPath(rect: rect)
            path.fill()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawHint() {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        let padding: CGFloat = 8
        let box = NSRect(
            x: bounds.midX - size.width / 2 - padding,
            y: bounds.midY - size.height / 2 - padding,
            width: size.width + padding * 2,
            height: size.height + padding * 2
        )
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor(white: 0, alpha: 0.72).setFill()
        path.fill()
        text.draw(at: NSPoint(x: box.minX + padding, y: box.minY + padding))
    }

    private func drawLabel() {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        let padding: CGFloat = 6
        let box = NSRect(
            x: selection.minX,
            y: selection.minY - size.height - padding * 2 - 6,
            width: size.width + padding * 2,
            height: size.height + padding * 2
        )
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        NSColor(white: 0, alpha: 0.75).setFill()
        path.fill()
        text.draw(at: NSPoint(x: box.minX + padding, y: box.minY + padding))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = globalPoint(for: event.locationInWindow)
        delegate?.overlayMouseDown(self, globalPoint: point)
        // Double-click copies and exits. The normal press is handled first so
        // that a double-click that starts a new selection still works.
        if event.clickCount >= 2 {
            delegate?.overlayDoubleClicked(self, globalPoint: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        delegate?.overlayMouseDragged(self, globalPoint: globalPoint(for: event.locationInWindow))
    }

    override func mouseUp(with event: NSEvent) {
        delegate?.overlayMouseUp(self, globalPoint: globalPoint(for: event.locationInWindow))
    }

    override func mouseMoved(with event: NSEvent) {
        delegate?.overlayMouseMoved(self, globalPoint: globalPoint(for: event.locationInWindow))
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.overlayRightClicked(self)
    }

    private func globalPoint(for local: NSPoint) -> NSPoint {
        guard let window = window else { return local }
        let f = window.frame
        return NSPoint(x: f.minX + local.x, y: f.minY + local.y)
    }
}
