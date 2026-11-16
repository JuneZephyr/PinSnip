import AppKit
import CoreGraphics
import Foundation

/// Posts a vertical scroll to the window underneath the selection, not to
/// whichever window happens to have keyboard focus.
enum ScrollSender {

    /// Scrolls down by `points` points inside `region` (CoreGraphics space).
    static func scrollDown(points: CGFloat, in region: CGRect) {
        guard Permissions.canSendScrollEvents else { return }

        let source = CGEventSource(stateID: .combinedSessionState)
        let delta = Int32(-max(1, points.rounded()))
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else { return }

        let center = CGPoint(x: region.midX, y: region.midY)
        event.location = center

        // Only ever scroll the window under the selection. Posting to the whole
        // session when no window is found would scroll whatever happens to be
        // under the pointer, including windows the selection never touches.
        guard let pid = windowOwner(at: center),
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        event.postToPid(pid)
    }

    /// The process that owns the normal-level window under a point.
    private static func windowOwner(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { continue }
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = number(bounds["X"]),
                  let y = number(bounds["Y"]),
                  let width = number(bounds["Width"]),
                  let height = number(bounds["Height"]) else { continue }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            if rect.contains(point) {
                return pid
            }
        }
        return nil
    }

    private static func number(_ value: Any?) -> CGFloat? {
        if let value = value as? CGFloat { return value }
        if let value = value as? NSNumber { return CGFloat(value.doubleValue) }
        if let value = value as? Int { return CGFloat(value) }
        if let value = value as? Double { return CGFloat(value) }
        return nil
    }
}
