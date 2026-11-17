import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// One captured display: the static frame plus everything needed to crop
/// screen regions out of it later.
struct DisplaySnap {
    let displayID: CGDirectDisplayID
    let display: SCDisplay
    let image: CGImage
    let screen: NSScreen?
    let scale: CGFloat
}

enum CaptureError: Error, LocalizedError {
    case permissionMissing
    case noContent
    case timeout
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionMissing: return "没有屏幕录制权限"
        case .noContent: return "没有可抓取的画面"
        case .timeout: return "截图超时：系统没有响应，请再试一次"
        case .failed(let message): return message
        }
    }
}

/// Wraps ScreenCaptureKit. Every capture is a still frame, so the pixels the
/// user selects never change while the selection overlay is up.
final class CaptureEngine {

    static let shared = CaptureEngine()

    private init() {}

    /// Windows that must never appear in a capture: the pin windows and the
    /// selection overlay itself.
    var excludedWindowIDs: () -> [CGWindowID] = { [] }

    private var content: SCShareableContent?
    private var configs: [CGDirectDisplayID: SCStreamConfiguration] = [:]

    /// ScreenCaptureKit can stay silent when the permission is in a bad state.
    /// Every call into it is bounded so a capture can never hang forever.
    private static let timeoutSeconds: TimeInterval = 20

    /// Races `body` against a timer. `finish` is safe to call more than once.
    private func withTimeout<T>(
        _ seconds: TimeInterval,
        _ body: @escaping (_ finish: @escaping (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            var finished = false
            let lock = NSLock()

            let finish: (Result<T, Error>) -> Void = { result in
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                lock.unlock()
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                finish(.failure(CaptureError.timeout))
            }
            body(finish)
        }
    }

    // MARK: - Preparation

    /// Fetches the shareable content and prepares one capture configuration per
    /// display. Must run before any capture.
    func prepare() async throws {
        guard Permissions.screenRecordingGranted else { throw CaptureError.permissionMissing }

        let info: SCShareableContent = try await withTimeout(CaptureEngine.timeoutSeconds) { finish in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error {
                    finish(.failure(CaptureError.failed(error.localizedDescription)))
                } else if let content {
                    finish(.success(content))
                } else {
                    finish(.failure(CaptureError.noContent))
                }
            }
        }

        content = info
        configs.removeAll()

        for display in info.displays {
            // The filter is only used to read this display's point/pixel scale;
            // the real filter is built per capture so freshly created pins and
            // overlays are always left out.
            let probe = SCContentFilter(display: display, excludingWindows: [])
            let pointScale = CGFloat(probe.pointPixelScale)

            let config = SCStreamConfiguration()
            config.width = Int((CGFloat(display.width) * pointScale).rounded())
            config.height = Int((CGFloat(display.height) * pointScale).rounded())
            config.showsCursor = false
            config.captureResolution = .best

            configs[display.displayID] = config
        }

        guard !configs.isEmpty else { throw CaptureError.noContent }
    }

    /// Captures every display once. Used for the frozen backdrop under the
    /// selection overlay.
    func captureAll() async throws -> [DisplaySnap] {
        if content == nil { try await prepare() }
        var snaps: [DisplaySnap] = []
        for displayID in configs.keys {
            if let snap = try? await capture(displayID: displayID) {
                snaps.append(snap)
            }
        }
        guard !snaps.isEmpty else { throw CaptureError.noContent }
        return snaps
    }

    /// Captures a single display at its native pixel size. The exclusion list is
    /// re-read every time, so windows created since the last capture (a new pin,
    /// the overlay itself) are never captured.
    func capture(displayID: CGDirectDisplayID) async throws -> DisplaySnap {
        guard let content, let display = content.displays.first(where: { $0.displayID == displayID }),
              let config = configs[displayID] else {
            throw CaptureError.noContent
        }

        // The shareable-content list is taken once, before the overlay exists.
        // Excluding our own application drops the selection border, the toolbar
        // and the preview even when those windows were created afterwards.
        // A border left inside the crop becomes a blue line at every join.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let filter: SCContentFilter
        if ownApps.isEmpty {
            let excluded = exclusionSet()
            let excludedWindows = content.windows.filter { excluded.contains($0.windowID) }
            filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        } else {
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        }

        let image = try await captureImage(contentFilter: filter, configuration: config)
        let scale = config.width > 0 ? CGFloat(config.width) / CGFloat(display.width) : 1
        return DisplaySnap(
            displayID: displayID,
            display: display,
            image: image,
            screen: Geometry.screen(forCGPoint: CGPoint(x: display.frame.midX, y: display.frame.midY)),
            scale: scale
        )
    }

    /// The windows to leave out, read on the main thread even when the capture
    /// comes from the long-screenshot queue: the pin list and the overlay list
    /// are main-thread state.
    private func exclusionSet() -> Set<CGWindowID> {
        if Thread.isMainThread {
            return Set(excludedWindowIDs())
        }
        var ids: [CGWindowID] = []
        DispatchQueue.main.sync { ids = excludedWindowIDs() }
        return Set(ids)
    }

    /// Captures the current contents of a CoreGraphics-space rectangle.
    func captureRect(_ rect: CGRect, displayID: CGDirectDisplayID) async throws -> CGImage {
        let snap = try await capture(displayID: displayID)
        guard let cropped = crop(snap.image, rect: rect, snap: snap) else {
            throw CaptureError.noContent
        }
        return cropped
    }

    /// Crops a CoreGraphics-space rectangle out of a full display image.
    func crop(_ image: CGImage, rect: CGRect, snap: DisplaySnap) -> CGImage? {
        let scaleX = snap.scale
        let scaleY = snap.scale
        let displayFrame = snap.display.frame

        let pixelRect = CGRect(
            x: (rect.minX - displayFrame.minX) * scaleX,
            y: (rect.minY - displayFrame.minY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let bounded = pixelRect.intersection(bounds)
        guard bounded.width >= 1, bounded.height >= 1 else { return nil }

        let integral = CGRect(
            x: floor(bounded.minX),
            y: floor(bounded.minY),
            width: min(ceil(bounded.width), bounds.width - floor(bounded.minX)),
            height: min(ceil(bounded.height), bounds.height - floor(bounded.minY))
        )
        guard integral.width >= 1, integral.height >= 1 else { return nil }
        return image.cropping(to: integral)
    }

    /// The display that contains a CoreGraphics point.
    func displayID(for point: CGPoint) -> CGDirectDisplayID? {
        guard let content else { return nil }
        return content.displays.first { display in
            display.frame.contains(point)
        }?.displayID ?? content.displays.first?.displayID
    }

    // MARK: - Screenshot call

    private func captureImage(contentFilter: SCContentFilter,
                             configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withTimeout(CaptureEngine.timeoutSeconds) { finish in
            SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: configuration) { image, error in
                if let error {
                    finish(.failure(CaptureError.failed(error.localizedDescription)))
                } else if let image {
                    finish(.success(image))
                } else {
                    finish(.failure(CaptureError.noContent))
                }
            }
        }
    }
}
