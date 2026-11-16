import AppKit

/// Draws clipboard text into an image so that text and pictures can share the
/// same pin window.
enum TextCard {

    /// A card taller than this cannot be read on a screen, so it is cut off and
    /// the card says so.
    private static let maximumHeight: CGFloat = 20_000
    private static let maximumCharacters = 12_000

    static func render(_ text: String, maxWidth: CGFloat = 460) -> NSImage {
        let font = NSFont.systemFont(ofSize: 14, weight: .regular)
        let padding: CGFloat = 16
        let lineSpacing: CGFloat = 4

        let truncated = text.count > maximumCharacters
        let source = truncated ? String(text.prefix(maximumCharacters)) : text

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: source, attributes: attributes)

        let constraint = NSSize(width: maxWidth, height: .greatestFiniteMagnitude)
        var bounding = attributed.boundingRect(
            with: constraint,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        if bounding.width > maxWidth { bounding.size.width = maxWidth }
        if bounding.height.isNaN || bounding.height < 1 { bounding.size.height = font.pointSize * 1.4 }

        let contentWidth = ceil(bounding.width)
        var contentHeight = ceil(bounding.height)
        let clipped = contentHeight > maximumHeight - padding * 2
        if clipped { contentHeight = maximumHeight - padding * 2 }

        let size = NSSize(
            width: contentWidth + padding * 2,
            height: contentHeight + padding * 2
        )
        let marker = truncated || clipped

        let image = NSImage(size: size, flipped: false) { rect in
            let background = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 10,
                yRadius: 10
            )
            NSColor(white: 0.08, alpha: 0.94).setFill()
            background.fill()

            let border = NSBezierPath(
                roundedRect: rect.insetBy(dx: 1, dy: 1),
                xRadius: 9,
                yRadius: 9
            )
            NSColor(white: 1, alpha: 0.12).setStroke()
            border.lineWidth = 1
            border.stroke()

            let content = NSRect(x: padding, y: padding, width: contentWidth, height: contentHeight)
            NSBezierPath(rect: content).addClip()
            attributed.draw(
                with: NSRect(
                    x: padding,
                    y: padding,
                    width: contentWidth,
                    height: ceil(bounding.height)
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )

            if marker {
                drawMarker(in: rect, padding: padding)
            }
            return true
        }
        return image
    }

    private static func drawMarker(in rect: NSRect, padding: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.65)
        ]
        let attributed = NSAttributedString(string: "内容过长，已截断", attributes: attributes)
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: rect.width - size.width - padding, y: 3))
    }
}
