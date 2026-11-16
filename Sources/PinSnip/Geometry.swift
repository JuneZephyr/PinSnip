import AppKit
import CoreGraphics
import Foundation

/// Coordinate helpers.
///
/// Two global spaces are used in this app:
///  * CoreGraphics space: origin at the top-left of the main display, y grows
///    downward. Used by ScreenCaptureKit frames, `CGEvent` and `CGImage`.
///  * Cocoa space: origin at the bottom-left of the main display, y grows
///    upward. Used by `NSWindow`, `NSScreen` and `NSEvent.mouseLocation`.
enum Geometry {

    /// Height of the main display in points (Cocoa space). Taken from the
    /// primary display's CoreGraphics bounds so it always matches the origin
    /// the CoreGraphics conversions below assume.
    static var mainDisplayHeight: CGFloat {
        CGFloat(CGDisplayBounds(CGMainDisplayID()).height)
    }

    /// Convert a CoreGraphics rect (y down) to a Cocoa rect (y up).
    static func nsRect(fromCG r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: mainDisplayHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Convert a Cocoa rect (y up) to a CoreGraphics rect (y down).
    static func cgRect(fromNS r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: mainDisplayHeight - r.maxY, width: r.width, height: r.height)
    }

    /// A CoreGraphics rect expressed in the coordinate space of `screen`
    /// (origin at that screen's bottom-left corner). Pass this to
    /// `NSWindow.setFrame(_:display: true)`.
    static func nsRectInScreen(_ r: CGRect, screen: NSScreen) -> NSRect {
        // Go through Cocoa global space first: subtracting the screen origin
        // from the flipped rect only works for screens that all share the main
        // display's height. A display placed above or below another one would
        // land in the wrong place.
        let global = nsRect(fromCG: r)
        return NSRect(x: global.minX - screen.frame.minX,
                      y: global.minY - screen.frame.minY,
                      width: global.width,
                      height: global.height)
    }

    /// The screen whose Cocoa frame contains a CoreGraphics point.
    static func screen(forCGPoint p: CGPoint) -> NSScreen? {
        let ns = NSPoint(x: p.x, y: mainDisplayHeight - p.y)
        return NSScreen.screens.first { NSPointInRect(ns, $0.frame) } ?? NSScreen.main
    }

    /// The screen whose Cocoa frame contains a Cocoa point.
    static func screen(forNSPoint p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSPointInRect(p, $0.frame) } ?? NSScreen.main
    }

    /// Convert a global Cocoa point to a global CoreGraphics point.
    static func cgPoint(fromNS p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: mainDisplayHeight - p.y)
    }

    /// Convert a global CoreGraphics point to a global Cocoa point.
    static func nsPoint(fromCG p: CGPoint) -> NSPoint {
        NSPoint(x: p.x, y: mainDisplayHeight - p.y)
    }
}
