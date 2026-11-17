import AppKit

enum AnnotateTool {
    case shape
    case arrow
    case pen
    case text
    case mosaic
}

enum ShapeKind {
    case rectangle
    case oval
    case line
}

struct StrokeStyle {
    var color: NSColor
    var width: CGFloat
    var filled: Bool
}

/// Settings shared by the five annotation tools. Values match the reference bars.
final class AnnotateStyle {
    var shapeKind: ShapeKind = .rectangle
    var filled = false
    var lineWidth: CGFloat = 4
    var color = NSColor(srgbRed: 0.93, green: 0.25, blue: 0.22, alpha: 1)
    var textSize: CGFloat = 50
    var textBackground: NSColor?
    var mosaicManual = true
    var mosaicBlur = false
    var mosaicBrush = false
    var mosaicPixel: CGFloat = 5

    static let palette: [NSColor] = [
        NSColor(srgbRed: 0.93, green: 0.25, blue: 0.22, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.82, blue: 0.18, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.58, green: 0.32, blue: 0.89, alpha: 1),
        .black,
        .white
    ]

    var stroke: StrokeStyle {
        StrokeStyle(color: color, width: max(1, lineWidth), filled: filled)
    }
}

enum AnnotationMark {
    case shape(ShapeKind, NSRect, StrokeStyle)
    case line(NSPoint, NSPoint, StrokeStyle)
    case arrow(NSPoint, NSPoint, StrokeStyle)
    case pen([NSPoint], StrokeStyle)
    case text(NSRect, String, CGFloat, NSColor, NSColor?)
    case mosaic(NSRect, CGFloat, Bool)
    case mosaicBrush([NSPoint], CGFloat, Bool)

    /// True only for marks that read the frozen picture to build their pixels,
    /// so the full-display buffer is not allocated for plain shapes.
    var needsPixels: Bool {
        switch self {
        case .mosaic, .mosaicBrush: return true
        default: return false
        }
    }

    var bounds: NSRect {
        switch self {
        case .shape(_, let rect, _), .text(let rect, _, _, _, _), .mosaic(let rect, _, _):
            return rect.standardized
        case .line(let from, let to, _), .arrow(let from, let to, _):
            return NSRect(
                x: min(from.x, to.x),
                y: min(from.y, to.y),
                width: max(1, abs(to.x - from.x)),
                height: max(1, abs(to.y - from.y))
            )
        case .pen(let points, _), .mosaicBrush(let points, _, _):
            guard let first = points.first else { return .zero }
            return points.reduce(NSRect(origin: first, size: .zero)) { rect, point in
                rect.union(NSRect(origin: point, size: .zero))
            }
        }
    }

    /// Boxes, lines, arrows and text can be grabbed after they are drawn.
    func hit(_ point: NSPoint) -> Bool {
        switch self {
        case .shape(let kind, let rect, let style):
            if kind == .line {
                return segmentDistance(rectLine(rect), point) <= max(8, style.width + 4)
            }
            return shapeContains(rect.standardized, point, tolerance: max(8, style.width + 4), filled: style.filled)
        case .line(let from, let to, let style):
            return segmentDistance((from, to), point) <= max(8, style.width + 4)
        case .arrow(let from, let to, let style):
            return segmentDistance((from, to), point) <= max(10, style.width + 6)
        case .pen(let points, let style):
            let reach = max(8, style.width + 4)
            guard points.count >= 2 else {
                return points.first.map { hypot($0.x - point.x, $0.y - point.y) <= reach } ?? false
            }
            for index in 1..<points.count where segmentDistance((points[index - 1], points[index]), point) <= reach {
                return true
            }
            return false
        case .text(let rect, _, _, _, _):
            return rect.insetBy(dx: -6, dy: -4).contains(point)
        default:
            return false
        }
    }

    func translated(dx: CGFloat, dy: CGFloat) -> AnnotationMark {
        switch self {
        case .shape(let kind, let rect, let style):
            return .shape(kind, rect.offsetBy(dx: dx, dy: dy), style)
        case .line(let from, let to, let style):
            return .line(shift(from, dx, dy), shift(to, dx, dy), style)
        case .arrow(let from, let to, let style):
            return .arrow(shift(from, dx, dy), shift(to, dx, dy), style)
        case .pen(let points, let style):
            return .pen(points.map { shift($0, dx, dy) }, style)
        case .text(let rect, let string, let size, let color, let background):
            return .text(rect.offsetBy(dx: dx, dy: dy), string, size, color, background)
        case .mosaic(let rect, let pixel, let blur):
            return .mosaic(rect.offsetBy(dx: dx, dy: dy), pixel, blur)
        case .mosaicBrush(let points, let pixel, let blur):
            return .mosaicBrush(points.map { shift($0, dx, dy) }, pixel, blur)
        }
    }

    func applying(_ style: AnnotateStyle) -> AnnotationMark {
        let stroke = style.stroke
        switch self {
        case .shape(let kind, let rect, _):
            return .shape(kind, rect, stroke)
        case .line(let from, let to, _):
            return .line(from, to, stroke)
        case .arrow(let from, let to, _):
            return .arrow(from, to, stroke)
        case .pen(let points, _):
            return .pen(points, stroke)
        case .text(let rect, let string, let size, _, _):
            var next = rect
            if abs(style.textSize - size) > 0.5 {
                next.size.height = max(next.height, style.textSize * 1.35)
            }
            return .text(next, string, style.textSize, style.color, style.textBackground)
        default:
            return self
        }
    }

    private func shapeContains(_ rect: NSRect, _ point: NSPoint, tolerance: CGFloat, filled: Bool) -> Bool {
        let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard outer.contains(point) else { return false }
        if filled { return true }
        let inner = rect.insetBy(dx: tolerance, dy: tolerance)
        if inner.width < 4 || inner.height < 4 { return true }
        return !inner.contains(point)
    }

    private func rectLine(_ rect: NSRect) -> (NSPoint, NSPoint) {
        let rect = rect.standardized
        return (NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.maxY))
    }

    private func segmentDistance(_ segment: (NSPoint, NSPoint), _ point: NSPoint) -> CGFloat {
        let from = segment.0
        let to = segment.1
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = dx * dx + dy * dy
        if length < 1 { return hypot(point.x - from.x, point.y - from.y) }
        let t = min(1, max(0, ((point.x - from.x) * dx + (point.y - from.y) * dy) / length))
        return hypot(point.x - (from.x + t * dx), point.y - (from.y + t * dy))
    }

    private func shift(_ point: NSPoint, _ dx: CGFloat, _ dy: CGFloat) -> NSPoint {
        NSPoint(x: point.x + dx, y: point.y + dy)
    }

    func draw(pixels: PixelBuffer?) {
        switch self {
        case .shape(let kind, let rect, let style):
            drawShape(kind, rect.standardized, style)
        case .line(let from, let to, let style):
            strokeLine(from: from, to: to, width: style.width, color: style.color)
        case .arrow(let from, let to, let style):
            drawArrow(from: from, to: to, style: style)
        case .pen(let points, let style):
            drawPen(points, style)
        case .text(let rect, let string, let size, let color, let background):
            drawText(rect, string, size, color, background)
        case .mosaic(let rect, let pixel, let blur):
            MosaicPainter.fill(rect.standardized, pixel: pixel, blur: blur, pixels: pixels)
        case .mosaicBrush(let points, let pixel, let blur):
            let side = max(4, pixel * 3)
            for point in points {
                let rect = NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
                MosaicPainter.fill(rect, pixel: pixel, blur: blur, pixels: pixels)
            }
        }
    }

    private func drawShape(_ kind: ShapeKind, _ rect: NSRect, _ style: StrokeStyle) {
        guard rect.width > 0.5 || rect.height > 0.5 else { return }
        let path: NSBezierPath
        switch kind {
        case .rectangle:
            path = NSBezierPath(rect: rect)
        case .oval:
            path = NSBezierPath(ovalIn: rect)
        case .line:
            strokeLine(from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.maxX, y: rect.maxY), width: style.width, color: style.color)
            return
        }
        style.color.set()
        if style.filled {
            path.fill()
        } else {
            path.lineWidth = style.width
            path.stroke()
        }
    }

    private func drawArrow(from: NSPoint, to: NSPoint, style: StrokeStyle) {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 1 else { return }
        let head = max(10, style.width * 3.2)
        let angle = atan2(to.y - from.y, to.x - from.x)
        let shaftEnd = NSPoint(
            x: to.x - cos(angle) * head * 0.72,
            y: to.y - sin(angle) * head * 0.72
        )
        strokeLine(from: from, to: shaftEnd, width: style.width, color: style.color)

        let wing = CGFloat.pi / 7
        let tip = NSBezierPath()
        tip.move(to: to)
        tip.line(to: NSPoint(x: to.x - cos(angle - wing) * head, y: to.y - sin(angle - wing) * head))
        tip.line(to: NSPoint(x: to.x - cos(angle + wing) * head, y: to.y - sin(angle + wing) * head))
        tip.close()
        style.color.setFill()
        tip.fill()
    }

    private func drawPen(_ points: [NSPoint], _ style: StrokeStyle) {
        guard let first = points.first else { return }
        if points.count == 1 {
            let radius = style.width / 2
            style.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: first.x - radius, y: first.y - radius, width: style.width, height: style.width)).fill()
            return
        }
        let path = NSBezierPath()
        path.lineWidth = style.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        style.color.setStroke()
        path.stroke()
    }

    private func drawText(_ rect: NSRect, _ string: String, _ size: CGFloat, _ color: NSColor, _ background: NSColor?) {
        guard !string.isEmpty else { return }
        if let background {
            background.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }
        let text = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color
        ])
        text.draw(in: rect.insetBy(dx: 2, dy: 1))
    }

    private func strokeLine(from: NSPoint, to: NSPoint, width: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.move(to: from)
        path.line(to: to)
        color.setStroke()
        path.stroke()
    }
}

enum MosaicPainter {
    static func fill(_ rect: NSRect, pixel: CGFloat, blur: Bool, pixels: PixelBuffer?) {
        let area = rect.standardized
        guard area.width >= 1, area.height >= 1 else { return }
        guard let pixels else {
            NSColor(white: 0.5, alpha: 0.45).setFill()
            area.fill()
            return
        }
        let step = max(2, blur ? pixel * 2.4 : pixel)
        var y = area.minY
        while y < area.maxY {
            let height = min(step, area.maxY - y)
            var x = area.minX
            while x < area.maxX {
                let width = min(step, area.maxX - x)
                let sample = NSPoint(x: x + width / 2, y: y + height / 2)
                let color = blur ? pixels.average(at: sample, radius: step) : pixels.color(at: sample)
                color.setFill()
                NSRect(x: x, y: y, width: width, height: height).fill()
                x += step
            }
            y += step
        }
    }
}

/// Full-display pixels, row 0 at the top of the picture. Points arrive in the
/// overlay's y-up view space, so lookups mirror y.
final class PixelBuffer {
    let width: Int
    let height: Int
    let bytes: [UInt8]
    let viewSize: CGSize

    init?(image: CGImage, viewSize: CGSize) {
        guard image.width > 0, image.height > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }
        width = image.width
        height = image.height
        self.viewSize = viewSize
        guard let storage = PixelBuffer.render(image, width: width, height: height) else { return nil }
        bytes = storage
    }

    private static func render(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var storage = [UInt8](repeating: 0, count: width * height * 4)
        let ok = storage.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? storage : nil
    }

    func color(at point: NSPoint) -> NSColor {
        let (px, py) = pixel(at: point)
        return colorAt(px, py)
    }

    func average(at point: NSPoint, radius: CGFloat) -> NSColor {
        let (px, py) = pixel(at: point)
        let reach = max(1, Int(radius))
        var red = 0
        var green = 0
        var blue = 0
        var count = 0
        for y in stride(from: py - reach, through: py + reach, by: max(1, reach / 2)) {
            for x in stride(from: px - reach, through: px + reach, by: max(1, reach / 2)) {
                let sampleX = min(max(x, 0), width - 1)
                let sampleY = min(max(y, 0), height - 1)
                let index = (sampleY * width + sampleX) * 4
                red += Int(bytes[index])
                green += Int(bytes[index + 1])
                blue += Int(bytes[index + 2])
                count += 1
            }
        }
        guard count > 0 else { return colorAt(px, py) }
        return NSColor(
            srgbRed: CGFloat(red / count) / 255,
            green: CGFloat(green / count) / 255,
            blue: CGFloat(blue / count) / 255,
            alpha: 1
        )
    }

    private func pixel(at point: NSPoint) -> (Int, Int) {
        let px = Int(point.x / viewSize.width * CGFloat(width))
        // Row 0 is the top of the picture, but the point is measured up from
        // the bottom of the view.
        let fromTop = viewSize.height - point.y
        let py = Int(fromTop / viewSize.height * CGFloat(height))
        return (min(max(px, 0), width - 1), min(max(py, 0), height - 1))
    }

    private func colorAt(_ x: Int, _ y: Int) -> NSColor {
        let index = (y * width + x) * 4
        return NSColor(
            srgbRed: CGFloat(bytes[index]) / 255,
            green: CGFloat(bytes[index + 1]) / 255,
            blue: CGFloat(bytes[index + 2]) / 255,
            alpha: 1
        )
    }
}

enum AnnotationDraw {
    static func composite(crop: CGImage, selection: NSRect, marks: [AnnotationMark], pixels: PixelBuffer?) -> CGImage? {
        let width = crop.width
        let height = crop.height
        guard width > 0, height > 0, selection.width > 0, selection.height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scale = CGFloat(width) / selection.width
        context.saveGState()
        context.translateBy(x: -selection.minX * scale, y: -selection.minY * scale)
        context.scaleBy(x: scale, y: scale)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSBezierPath(rect: selection).addClip()
        for mark in marks {
            mark.draw(pixels: pixels)
        }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        return context.makeImage()
    }
}
