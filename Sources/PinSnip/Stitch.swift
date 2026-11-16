import CoreGraphics
import Foundation

/// A growable RGBA canvas that rows can be appended to. The logical row 0 is
/// the top of the image, so the drawing context is flipped.
final class StitchBuffer {

    private(set) var width: Int
    private(set) var height: Int = 0
    private var capacity: Int
    private var context: CGContext?

    /// Hard ceiling so a very long chat log cannot exhaust memory.
    var maxHeight: Int = 30000

    init(width: Int, initialHeight: Int) {
        self.width = max(1, width)
        self.capacity = max(1, min(initialHeight, maxHeight))
        self.context = StitchBuffer.makeContext(width: self.width, height: capacity)
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    func appendRows(_ strip: CGImage, rows: Int) {
        guard rows > 0 else { return }
        let allowed = min(rows, max(0, maxHeight - height))
        guard allowed > 0 else { return }

        if height + allowed > capacity {
            let target = min(max(height + allowed, capacity * 2), maxHeight)
            if target > capacity {
                grow(to: target)
            }
        }
        guard height + allowed <= capacity, let context else { return }

        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(capacity))
        context.scaleBy(x: 1, y: -1)
        context.draw(strip, in: CGRect(x: 0, y: height, width: width, height: allowed))
        context.restoreGState()
        height += allowed
    }

    private func grow(to newCapacity: Int) {
        guard newCapacity > capacity,
              let newContext = StitchBuffer.makeContext(width: width, height: newCapacity) else { return }
        newContext.saveGState()
        newContext.translateBy(x: 0, y: CGFloat(newCapacity))
        newContext.scaleBy(x: 1, y: -1)
        if let previous = context?.makeImage() {
            newContext.draw(previous, in: CGRect(x: 0, y: 0, width: width, height: capacity))
        }
        newContext.restoreGState()
        context = newContext
        capacity = newCapacity
    }

    func makeImage() -> CGImage? {
        guard let full = context?.makeImage() else { return nil }
        guard height < full.height else { return full }
        return full.cropping(to: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

/// Vertical offset detection and row extraction for the long screenshot.
enum Stitcher {

    struct Shift {
        let pixels: Int
        let quality: Double
    }

    /// The bottom `rows` of `image` — the part that has just been revealed.
    static func newRows(from image: CGImage, rows: Int) -> CGImage? {
        let count = min(max(0, rows), image.height)
        guard count > 0 else { return nil }
        return image.cropping(to: CGRect(x: 0, y: image.height - count, width: image.width, height: count))
    }

    /// Finds how far the content moved between two frames by matching a strip
    /// taken from the bottom of the previous frame against the new frame.
    static func shift(previous: CGImage, new: CGImage) -> Shift? {
        guard previous.width == new.width, previous.height == new.height else { return nil }
        guard previous.width > 8, previous.height > 8 else { return nil }

        let smallWidth = max(2, previous.width / 4)
        let smallHeight = max(8, previous.height / 4)
        guard let a = ImageMath.rgba(previous, width: smallWidth, height: smallHeight),
              let b = ImageMath.rgba(new, width: smallWidth, height: smallHeight) else { return nil }

        let strip = max(3, smallHeight / 8)
        let limit = smallHeight - strip
        var bestY = 0
        var bestScore = Double.greatestFiniteMagnitude

        for candidate in 0...limit {
            var score = 0.0
            for row in 0..<strip {
                let aRow = (smallHeight - strip + row) * smallWidth
                let bRow = (candidate + row) * smallWidth
                for column in 0..<smallWidth {
                    let aIndex = (aRow + column) * 4
                    let bIndex = (bRow + column) * 4
                    score += Double(abs(Int(a[aIndex]) - Int(b[bIndex])))
                    score += Double(abs(Int(a[aIndex + 1]) - Int(b[bIndex + 1])))
                    score += Double(abs(Int(a[aIndex + 2]) - Int(b[bIndex + 2])))
                }
            }
            if score < bestScore {
                bestScore = score
                bestY = candidate
            }
        }

        let scale = CGFloat(previous.height) / CGFloat(smallHeight)
        let pixels = Int((CGFloat(limit - bestY) * scale).rounded())
        let quality = bestScore / Double(strip * smallWidth * 3)
        return Shift(pixels: max(0, pixels), quality: quality)
    }
}

/// Small pixel helpers shared by the stitcher and the stability detector.
enum ImageMath {

    /// Downsamples an image into a top-down RGBA buffer.
    static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .low
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
        return buffer
    }

    /// Mean absolute difference of two frames, 0 (identical) to 255.
    static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        let width = 48
        let height = 48
        guard let ba = rgba(a, width: width, height: height),
              let bb = rgba(b, width: width, height: height) else {
            return Double.greatestFiniteMagnitude
        }
        var sum = 0.0
        for index in stride(from: 0, to: ba.count, by: 4) {
            sum += Double(abs(Int(ba[index]) - Int(bb[index])))
            sum += Double(abs(Int(ba[index + 1]) - Int(bb[index + 1])))
            sum += Double(abs(Int(ba[index + 2]) - Int(bb[index + 2])))
        }
        return sum / Double(width * height * 3)
    }
}
