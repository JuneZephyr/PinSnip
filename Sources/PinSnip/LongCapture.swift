import AppKit
import CoreGraphics
import Foundation

/// Stitches a vertical long screenshot. The first frame is the selection the
/// user already made. Nothing scrolls until `beginAutoScroll()`; until then the
/// loop only extends the image when the page itself moves.
final class LongCapture {

    enum EndReason {
        case bottomReached
        case userStop
        case userDone
        case misaligned
        case limitReached
    }

    var onPreview: ((CGImage, Int) -> Void)?
    var onFinish: ((CGImage?, EndReason) -> Void)?

    private let region: CGRect
    private let displayID: CGDirectDisplayID
    private let maxHeight: Int
    private let seed: CGImage
    private let queue = DispatchQueue(label: "com.personal.pinsnip.longcapture", qos: .userInitiated)

    private var buffer: StitchBuffer?
    private var lastFrame: CGImage?
    private var noProgress = 0
    private var stopRequested = false
    private var finishRequested = false
    private var autoScroll = false
    private var stitchingEnabled = true
    private var finished = false

    init(region: CGRect, displayID: CGDirectDisplayID, maxHeight: Int, seed: CGImage) {
        self.region = region
        self.displayID = displayID
        self.maxHeight = max(1, maxHeight)
        self.seed = seed
    }

    func start() {
        queue.async { [weak self] in self?.run() }
    }

    /// The blue button. Scrolls the page downward until the user stops it.
    func beginAutoScroll() { autoScroll = true }

    /// A second click on the button returns to watching the user's own scroll.
    func endAutoScroll() { autoScroll = false }

    /// Horizontal stitching is not available, so that direction only watches.
    func setStitchingEnabled(_ enabled: Bool) { stitchingEnabled = enabled }

    /// Esc: keep what has been stitched so far and let the user decide.
    func requestStop() { stopRequested = true }

    /// Enter or the green check: treat the current image as complete.
    func requestFinish() { finishRequested = true }

    /// Throws the session away for good. No preview and no finish callback will
    /// arrive afterwards, so a cancelled session cannot come back to life with
    /// a stray toolbar on screen.
    func abandon() {
        stopRequested = true
        finished = true
        onPreview = nil
        onFinish = nil
    }

    // MARK: - Loop

    private func run() {
        let first = seed
        guard first.width > 0, first.height > 0 else {
            complete(nil, .misaligned)
            return
        }

        let buffer = StitchBuffer(width: first.width, initialHeight: min(first.height, maxHeight))
        buffer.maxHeight = maxHeight
        self.buffer = buffer
        buffer.appendRows(first, rows: min(first.height, maxHeight))
        lastFrame = first
        publishPreview()

        while !stopRequested && !finishRequested {
            guard let buffer = self.buffer else { break }

            if buffer.height >= maxHeight {
                complete(buffer.makeImage(), .limitReached)
                return
            }

            if autoScroll {
                scrollDown()
                if stopRequested || finishRequested { break }
                guard let frame = waitForStable() else {
                    complete(self.buffer?.makeImage(), .misaligned)
                    return
                }
                if !append(frame, endWhenStill: true) { return }
            } else if stitchingEnabled {
                guard let frame = waitForMovement() else { continue }
                if stopRequested || finishRequested || autoScroll { continue }
                if !append(frame, endWhenStill: false) { return }
            } else {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        complete(self.buffer?.makeImage(), stopRequested ? .userStop : .userDone)
    }

    /// Adds the newly revealed rows. Returns false when the session has ended.
    private func append(_ frame: CGImage, endWhenStill: Bool) -> Bool {
        guard let previous = lastFrame, let buffer else { return false }
        guard let shift = Stitcher.shift(previous: previous, new: frame), shift.quality <= 18 else {
            if endWhenStill {
                complete(buffer.makeImage(), .misaligned)
                return false
            }
            return true
        }

        if shift.pixels < 4 {
            if endWhenStill {
                noProgress += 1
                if noProgress >= 2 {
                    complete(buffer.makeImage(), .bottomReached)
                    return false
                }
                lastFrame = frame
            }
            return true
        }

        noProgress = 0
        guard let strip = Stitcher.newRows(from: frame, rows: shift.pixels) else {
            if endWhenStill {
                complete(buffer.makeImage(), .misaligned)
                return false
            }
            return true
        }
        buffer.appendRows(strip, rows: shift.pixels)
        lastFrame = frame
        publishPreview()
        return true
    }

    /// Blocks until the page under the selection actually changes.
    private func waitForMovement() -> CGImage? {
        while !stopRequested && !finishRequested && !autoScroll && stitchingEnabled {
            guard let frame = captureRegion() else {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            guard let previous = lastFrame else { return frame }
            if ImageMath.difference(previous, frame) >= 4 {
                return waitForStable() ?? frame
            }
            Thread.sleep(forTimeInterval: 0.18)
        }
        return nil
    }

    private func scrollDown() {
        let points = min(160, max(60, region.height * 0.45))
        ScrollSender.scrollDown(points: points, in: region)
    }

    /// Waits until two consecutive samples barely differ, with a floor so an
    /// animation that has not finished yet is not captured.
    private func waitForStable() -> CGImage? {
        let start = Date()
        let deadline = start.addingTimeInterval(4.0)
        var last: CGImage?
        var stableStreak = 0

        while Date() < deadline {
            if stopRequested || finishRequested { return last }
            guard let frame = captureRegion() else { return last }
            if let previous = last {
                stableStreak = ImageMath.difference(previous, frame) < 2.0 ? stableStreak + 1 : 0
            }
            last = frame
            if stableStreak >= 2, Date().timeIntervalSince(start) >= 0.15 {
                return frame
            }
            Thread.sleep(forTimeInterval: 0.04)
        }
        return last
    }

    // MARK: - Capture

    private func captureRegion() -> CGImage? {
        let ticket = CaptureTicket()
        let region = self.region
        let displayID = self.displayID
        Task.detached(priority: .userInitiated) {
            let image = try? await CaptureEngine.shared.captureRect(region, displayID: displayID)
            ticket.image = image
            ticket.semaphore.signal()
        }
        // A capture that never returns used to leave the session stuck.
        if ticket.semaphore.wait(timeout: .now() + 3) == .timedOut {
            return nil
        }
        return ticket.image
    }

    // MARK: - Callbacks

    private var lastPreviewAt = Date.distantPast

    /// Copies the whole canvas, which on a tall screenshot is hundreds of
    /// megabytes, so it is done a few times a second at most rather than on
    /// every appended frame.
    private func publishPreview() {
        let now = Date()
        guard now.timeIntervalSince(lastPreviewAt) >= 0.4 else { return }
        lastPreviewAt = now
        guard let image = buffer?.makeImage() else { return }
        let height = buffer?.height ?? 0
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }
            self.onPreview?(image, height)
        }
    }

    private final class CaptureTicket: @unchecked Sendable {
        var image: CGImage?
        let semaphore = DispatchSemaphore(value: 0)
    }

    private func complete(_ image: CGImage?, _ reason: EndReason) {
        guard !finished else { return }
        finished = true
        DispatchQueue.main.async { [weak self] in
            self?.onFinish?(image, reason)
        }
    }
}
