import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Drives one screenshot session: frozen backdrop, drag selection, action bar,
/// and the long screenshot loop.
final class SelectionController: NSObject {

    enum State {
        case idle
        case selecting
        case selected
        case capturingLong
        case result
    }

    private struct Entry {
        let window: OverlayWindow
        let view: OverlayView
        let screen: NSScreen
    }

    private(set) var state: State = .idle

    private var entries: [Entry] = []
    private var snaps: [DisplaySnap] = []
    private var toolbar: SelectionToolbar?
    private var preview: PreviewPanel?
    private var longCapture: LongCapture?
    private var longCaptureKeyMonitors: [Any] = []

    private var startScreen: NSScreen?
    private var startDisplayID: CGDirectDisplayID?
    private var dragStart: CGPoint = .zero
    private var dragOffset: CGSize = .zero
    private var dragMode: DragMode = .none
    private var resizeAnchor: CGRect = .zero

    private enum DragMode: Equatable {
        case none
        case creating
        case moving
        case resizing(ResizeEdges)
        case drawing
        case movingMark
    }

    /// Edges of the selection in CoreGraphics space, where y grows downward.
    private struct ResizeEdges: OptionSet {
        let rawValue: Int
        static let left = ResizeEdges(rawValue: 1 << 0)
        static let right = ResizeEdges(rawValue: 1 << 1)
        static let top = ResizeEdges(rawValue: 1 << 2)
        static let bottom = ResizeEdges(rawValue: 1 << 3)
    }

    private(set) var selectionCG: CGRect = .zero
    private var longImage: CGImage?
    private var growingImage: CGImage?
    private var autoScrollActive = false
    private var pendingExit: PendingExit?
    private var options: ToolOptionsBar?
    private let annotateStyle = AnnotateStyle()
    private var activeTool: AnnotateTool?
    private var selectedMark: Int?
    private var markDragOrigin: AnnotationMark?
    private var markDragAnchor = NSPoint.zero
    private var markDragMoved = false
    private var markHistory: [MarkHistory] = []
    private var moveHistory: MarkHistory?
    private var textHistory: MarkHistory?
    private var styleHistory: MarkHistory?
    private var styleGesture = false
    private var marks: [AnnotationMark] = []
    private var draft: AnnotationMark?
    private var pixels: PixelBuffer?
    private var drawAnchor: NSPoint = .zero
    private var textField: NSTextField?
    private weak var textHost: OverlayView?

    private enum PendingExit {
        case copy
        case pin
        case save
    }

    weak var app: AppEnvironment?

    private static let minimumSelection: CGFloat = 4

    // MARK: - Starting and stopping

    var isActive: Bool { state != .idle }

    /// Every window this session owns, so captures can leave them out.
    func captureExclusionWindowIDs() -> [CGWindowID] {
        var ids: [CGWindowID] = []
        for entry in entries where entry.window.windowNumber > 0 {
            ids.append(CGWindowID(entry.window.windowNumber))
        }
        for window in [toolbar, preview, options] {
            if let window, window.windowNumber > 0 {
                ids.append(CGWindowID(window.windowNumber))
            }
        }
        return ids
    }

    func start() {
        guard state == .idle else { return }
        guard Permissions.screenRecordingGranted else {
            Permissions.requestScreenRecording()
            app?.showPermissionAlert()
            return
        }

        state = .selecting
        selectionCG = .zero
        longImage = nil
        growingImage = nil
        dragMode = .none
        activeTool = nil
        marks.removeAll()
        draft = nil
        pixels = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snaps = try await CaptureEngine.shared.captureAll()
                self.snaps = snaps
                self.presentOverlays()
            } catch {
                self.state = .idle
                self.app?.showCaptureError(error)
            }
        }
    }

    func cancel() {
        // Cut the callbacks before dropping the loop: a finish that arrives a
        // moment later used to resurrect the session as a floating toolbar with
        // every hotkey still blocked.
        longCapture?.abandon()
        longCapture = nil
        growingImage = nil
        autoScrollActive = false
        pendingExit = nil
        removeLongCaptureKeyMonitors()

        toolbar?.orderOut(nil)
        toolbar?.close()
        toolbar = nil
        closeOptions()
        removeTextField()

        preview?.orderOut(nil)
        preview?.close()
        preview = nil

        for entry in entries {
            entry.window.orderOut(nil)
            entry.window.close()
        }
        entries.removeAll()
        snaps.removeAll()
        NSApp.setActivationPolicy(.accessory)

        selectionCG = .zero
        longImage = nil
        startScreen = nil
        startDisplayID = nil
        state = .idle
    }

    // MARK: - Overlays

    private func presentOverlays() {
        for snap in snaps {
            guard let screen = snap.screen ?? NSScreen.main else { continue }
            let window = OverlayWindow(screen: screen)
            window.controller = self
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.snapshot = snap.image
            view.label = "拖动选择区域 · Esc 取消 · 右键取消"
            view.delegate = self
            window.contentView = view
            entries.append(Entry(window: window, view: view, screen: screen))
        }
        // A menu-bar app cannot take clicks until it is allowed to become active.
        // Without this, the overlay covers the screen and then ignores the mouse.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for entry in entries {
            entry.window.makeKeyAndOrderFront(nil)
        }
        installSessionKeyMonitors()
    }

    // MARK: - Keyboard

    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        let command = event.modifierFlags.contains(.command)

        // While a text annotation is being typed the field owns the keyboard:
        // Return and Escape finish the text, and a letter like L must never
        // start the long capture behind the user's back. ⌘Z stays with the field.
        if textField != nil {
            if keyCode == 36 || keyCode == 76 || keyCode == 53 {
                commitText()
                return true
            }
            return false
        }

        if keyCode == 53 { // escape
            if state == .capturingLong {
                longCapture?.requestStop()
            } else {
                cancel()
            }
            return true
        }

        if keyCode == 36 || keyCode == 76 { // return / keypad enter
            confirm()
            return true
        }

        if command && keyCode == 6 && state == .selected
            && event.modifierFlags.intersection([.shift, .option, .control]).isEmpty {
            undoAnnotation()
            return true
        }

        if !command && keyCode == 37 && state == .selected {
            enterLongMode()
            return true
        }

        guard state == .selected || state == .result || state == .capturingLong else { return false }
        if command && keyCode == 17 { // ⌘T
            pinCurrent()
            return true
        }
        if command && keyCode == 1 { // ⌘S
            saveCurrent()
            return true
        }
        return false
    }

    // MARK: - Exits

    private func currentImage() -> (image: CGImage, pointSize: NSSize)? {
        let stitched = longImage ?? (state == .capturingLong ? growingImage : nil)
        if let stitched {
            let scale = currentScale()
            return (stitched, NSSize(width: CGFloat(stitched.width) / scale,
                                      height: CGFloat(stitched.height) / scale))
        }
        guard let displayID = startDisplayID,
              let snap = snaps.first(where: { $0.displayID == displayID }),
              let image = CaptureEngine.shared.crop(snap.image, rect: selectionCG, snap: snap) else {
            return nil
        }
        return (rendered(image), selectionCG.size)
    }

    private func currentScale() -> CGFloat {
        // The long image was captured on the selection's own display; using
        // another display's scale would give a wrong point size on mixed
        // Retina/non-Retina setups.
        if let displayID = startDisplayID,
           let snap = snaps.first(where: { $0.displayID == displayID }) {
            return snap.scale
        }
        return snaps.first?.scale ?? 2
    }

    func finishCopy() {
        guard let current = currentImage() else {
            cancel()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let image = NSImage(cgImage: current.image, size: current.pointSize)
        pasteboard.writeObjects([image])
        cancel()
    }

    func finishPin() {
        guard let current = currentImage() else {
            cancel()
            return
        }
        let image = NSImage(cgImage: current.image, size: current.pointSize)
        let center = Geometry.nsPoint(fromCG: CGPoint(x: selectionCG.midX, y: selectionCG.midY))
        app?.pins.pinImage(image, pointSize: current.pointSize, centeredAt: center)
        cancel()
    }

    func finishSave() {
        guard let current = currentImage() else {
            cancel()
            return
        }
        cancel()

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "截图 \(SelectionController.fileNameStamp()).png"
        panel.allowedContentTypes = [.png]
        // The capture session just gave up activation; without this the panel
        // can open behind whatever app is in front.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            SelectionController.writePNG(current.image, to: url)
        }
    }

    private static func fileNameStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    // MARK: - Long screenshot

    /// 长截图 replaces the icon bar with the auto-scroll bar and opens the page.
    /// The page does not move until 自动滚动 is clicked.
    private func enterLongMode() {
        beginLongCapture()
        guard state == .capturingLong else { return }
        toolbar?.showLongMode()
        positionToolbar()
        toolbar?.orderFrontRegardless()
    }

    /// Drops the frozen picture and waits. Scrolling starts only from 自动滚动.
    func beginLongCapture() {
        guard state == .selected, longCapture == nil else { return }
        guard let displayID = startDisplayID,
              let snap = snaps.first(where: { $0.displayID == displayID }),
              let cropped = CaptureEngine.shared.crop(snap.image, rect: selectionCG, snap: snap) else { return }
        let seed = rendered(cropped)

        state = .capturingLong
        closeOptions()
        activeTool = nil
        showLiveSelection()

        let displayPixelHeight = snap.image.height
        let maxHeight = min(30000, max(1, 20 * displayPixelHeight))
        // Manual mode does not stop on a still page or a bad match, so a
        // misaligned page would otherwise grow until maxHeight. Twenty copies
        // of the selection the user actually captured is the lower ceiling.
        let progressLimit = min(maxHeight, max(seed.height, 20 * seed.height))

        let capture = LongCapture(region: selectionCG, displayID: displayID,
                                  maxHeight: maxHeight, progressLimit: progressLimit, seed: seed)
        capture.setStitchingEnabled(toolbar?.direction != .horizontal)
        capture.onPreview = { [weak self] image, height in
            self?.growingImage = image
            self?.updatePreview(image: image, pixelHeight: height)
        }
        capture.onNotice = { [weak self] text in
            guard let self, let image = self.growingImage else { return }
            self.updatePreview(image: image, pixelHeight: image.height, caption: text)
        }
        capture.onFinish = { [weak self] image, reason in
            self?.longCaptureDidFinish(image, reason: reason)
        }
        longCapture = capture
        growingImage = seed
        capture.start()
        updatePreview(image: seed, pixelHeight: seed.height)
    }

    private func confirm() {
        if state == .capturingLong {
            pendingExit = .copy
            longCapture?.requestFinish()
            return
        }
        guard state == .selected || state == .result else { return }
        finishCopy()
    }

    private func pinCurrent() {
        if state == .capturingLong {
            pendingExit = .pin
            longCapture?.requestFinish()
            return
        }
        guard state == .selected || state == .result else { return }
        finishPin()
    }

    private func saveCurrent() {
        if state == .capturingLong {
            pendingExit = .save
            longCapture?.requestFinish()
            return
        }
        guard state == .selected || state == .result else { return }
        finishSave()
    }

    /// Manual mode: the page stays still until the user drags or scrolls it.
    private func useManualScroll() {
        guard state == .capturingLong, autoScrollActive else { return }
        autoScrollActive = false
        toolbar?.setAutoScrollActive(false)
        longCapture?.endAutoScroll()
        if let image = growingImage {
            updatePreview(image: image, pixelHeight: image.height)
        }
    }

    private func startAutoScroll() {
        guard state == .capturingLong else { return }
        if autoScrollActive {
            autoScrollActive = false
            toolbar?.setAutoScrollActive(false)
            longCapture?.endAutoScroll()
            if let image = growingImage {
                updatePreview(image: image, pixelHeight: image.height)
            }
            return
        }
        guard toolbar?.direction != .horizontal else {
            if let image = growingImage {
                updatePreview(image: image, pixelHeight: image.height, caption: "横向还不能拼接，请改回竖向")
            }
            return
        }
        guard Permissions.canSendScrollEvents else {
            Permissions.requestAccessibility()
            app?.showAccessibilityAlert()
            return
        }
        autoScrollActive = true
        toolbar?.setAutoScrollActive(true)
        longCapture?.beginAutoScroll()
        if let image = growingImage {
            updatePreview(image: image, pixelHeight: image.height, caption: "已拼接 \(image.height) px · 再点一次停止")
        }
    }

    private func longCaptureDidFinish(_ image: CGImage?, reason: LongCapture.EndReason) {
        longCapture = nil
        autoScrollActive = false
        toolbar?.setAutoScrollActive(false)

        guard let image, image.width > 0, image.height > 0 else {
            cancel()
            return
        }

        longImage = image
        growingImage = image
        state = .result

        let exit = pendingExit
        pendingExit = nil
        if let exit {
            switch exit {
            case .copy: finishCopy()
            case .pin: finishPin()
            case .save: finishSave()
            }
            return
        }

        let note: String
        switch reason {
        case .bottomReached: note = "已到页面底部"
        case .userStop: note = "已停止，保留已拼接部分"
        case .userDone: note = "已完成"
        case .misaligned: note = "这一帧对不齐，已在此停下"
        case .limitReached: note = "已达高度上限，已停止"
        case .manualLimit: note = "已达手动高度上限，已停止"
        }

        for entry in entries {
            entry.view.label = note
            entry.view.needsDisplay = true
        }

        updatePreview(image: image, pixelHeight: image.height, caption: "\(note) · 点 ✓ 复制")
        showToolbar()
    }

    /// Drops the frozen picture and leaves a click-through border, so the real
    /// page can be scrolled while the bar stays on screen.
    private func showLiveSelection() {
        for entry in entries {
            if entry.view.hasSelection {
                entry.view.snapshot = nil
                entry.view.label = ""
                entry.view.needsDisplay = true
                entry.window.ignoresMouseEvents = true
                entry.window.orderFrontRegardless()
            } else {
                entry.window.orderOut(nil)
            }
        }
        NSApp.setActivationPolicy(.accessory)
    }

    private func installSessionKeyMonitors() {
        removeLongCaptureKeyMonitors()
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                // A keystroke typed into another app only belongs to the
                // session while the long page is being scrolled (the app is
                // accessory there) or after it has finished. Acting on a
                // Return typed elsewhere during a still selection would
                // overwrite the clipboard with a screenshot.
                let isEscape = event.keyCode == 53
                guard isEscape || self.state == .capturingLong || self.state == .result else { return }
                self.handleKeyDown(event)
            }
        }) {
            longCaptureKeyMonitors.append(monitor)
        }
        // Local events are handled right here, before the key reaches the
        // window or a text field: a deferred call would let Return commit the
        // text and then copy the screenshot in one press.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if self?.handleKeyDown(event) == true {
                return nil
            }
            return event
        }) {
            longCaptureKeyMonitors.append(monitor)
        }
    }

    private func removeLongCaptureKeyMonitors() {
        for monitor in longCaptureKeyMonitors {
            NSEvent.removeMonitor(monitor)
        }
        longCaptureKeyMonitors.removeAll()
    }

    // MARK: - Toolbar and preview

    private func showToolbar() {
        guard state == .selected || state == .result else { return }
        if toolbar == nil {
            let bar = SelectionToolbar()
            bar.onCopy = { [weak self] in self?.confirm() }
            bar.onPin = { [weak self] in self?.pinCurrent() }
            bar.onSave = { [weak self] in self?.saveCurrent() }
            bar.onUndo = { [weak self] in self?.undoAnnotation() }
            bar.onCancel = { [weak self] in self?.cancel() }
            bar.onLong = { [weak self] in self?.enterLongMode() }
            bar.onAutoScroll = { [weak self] in self?.startAutoScroll() }
            bar.onManual = { [weak self] in self?.useManualScroll() }
            bar.onDirection = { [weak self] direction in
                self?.longCapture?.setStitchingEnabled(direction == .vertical)
            }
            bar.onTool = { [weak self] tool in self?.toggleTool(tool) }
            toolbar = bar
        }
        if state != .capturingLong {
            toolbar?.showTools()
            toolbar?.setActiveTool(activeTool)
            toolbar?.setUndoEnabled(!markHistory.isEmpty)
        }
        positionToolbar()
        positionOptions()
        toolbar?.orderFrontRegardless()
        options?.orderFrontRegardless()
    }

    private var activeScreen: NSScreen? {
        startScreen ?? Geometry.screen(forCGPoint: CGPoint(x: selectionCG.midX, y: selectionCG.midY)) ?? NSScreen.main
    }

    private func positionToolbar() {
        guard let toolbar, let screen = activeScreen else { return }
        let local = Geometry.nsRectInScreen(selectionCG, screen: screen)
        let size = toolbar.frame.size
        let margin: CGFloat = 8

        var origin = NSPoint(
            x: local.midX - size.width / 2,
            y: local.minY - size.height - margin
        )
        if origin.y < screen.frame.minY + 4 {
            origin.y = local.maxY + margin
        }
        origin.y = min(max(origin.y, screen.frame.minY + 4), screen.frame.maxY - size.height - 4)
        origin.x = min(max(origin.x, screen.frame.minX + 4), screen.frame.maxX - size.width - 4)

        toolbar.setFrameOrigin(origin)
    }

    private func updatePreview(image: CGImage, pixelHeight: Int, caption: String? = nil) {
        guard state == .capturingLong || state == .result else { return }
        guard let screen = activeScreen else { return }

        if preview == nil {
            preview = PreviewPanel()
        }
        preview?.update(
            image: image,
            pixelHeight: pixelHeight,
            maxScreenHeight: screen.frame.height * 0.7,
            caption: caption ?? (autoScrollActive
                ? "已拼接 \(pixelHeight) px · 再点一次停止"
                : "手动：拖动或滚动页面即可延长")
        )
        positionPreview()
        preview?.orderFrontRegardless()
    }

    private func positionPreview() {
        guard let preview, let screen = activeScreen else { return }
        let local = Geometry.nsRectInScreen(selectionCG, screen: screen)
        let size = preview.frame.size
        let margin: CGFloat = 12

        var originX = local.maxX + margin
        if originX + size.width > screen.frame.maxX - 4 {
            originX = local.minX - margin - size.width
        }
        if originX < screen.frame.minX + 4 {
            originX = local.maxX + margin
        }
        var originY = local.midY - size.height / 2
        originY = min(max(originY, screen.frame.minY + 4), screen.frame.maxY - size.height - 4)

        preview.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    // MARK: - Selection updates

    private func updateSelectionViews() {
        guard let screen = activeScreen else { return }
        let local = Geometry.nsRectInScreen(selectionCG, screen: screen)
        let hasSelection = selectionCG.width >= 1 && selectionCG.height >= 1

        for entry in entries {
            if entry.screen === screen {
                entry.view.selection = local
                entry.view.hasSelection = hasSelection
                if hasSelection, state != .capturingLong, state != .result {
                    entry.view.label = "\(Int(selectionCG.width)) × \(Int(selectionCG.height))"
                }
            } else {
                entry.view.selection = .zero
                entry.view.hasSelection = false
            }
            entry.view.needsDisplay = true
        }

        positionToolbar()
    }
}

// MARK: - OverlayViewDelegate

extension SelectionController: OverlayViewDelegate {

    func overlayMouseDown(_ view: OverlayView, globalPoint: NSPoint) {
        guard state == .selecting || state == .selected else { return }
        let point = Geometry.cgPoint(fromNS: globalPoint)
        guard let screen = Geometry.screen(forNSPoint: globalPoint) else { return }

        startScreen = screen
        startDisplayID = CaptureEngine.shared.displayID(for: point)

        if state == .selected {
            switch selectionHit(at: point) {
            case .resize(let edges):
                dragMode = .resizing(edges)
                resizeAnchor = selectionCG
                setResizeCursor(edges)
                return
            case .move:
                let local = viewPoint(view, globalPoint)
                if let index = hitMark(at: local) {
                    beginMovingMark(index, at: local)
                    return
                }
                selectedMark = nil
                if activeTool != nil, selectionCG.contains(point) {
                    beginDrawing(in: view, globalPoint: globalPoint)
                    return
                }
                dragMode = .moving
                dragOffset = CGSize(width: point.x - selectionCG.minX, height: point.y - selectionCG.minY)
                NSCursor.closedHand.set()
                return
            case .outside:
                break
            }
        }

        // A brand-new rectangle starts with a clean sheet: the annotations and
        // the pixel buffer belong to the old rectangle, possibly another
        // display.
        removeTextField()
        selectedMark = nil
        marks.removeAll()
        clearHistory()
        draft = nil
        pixels = nil
        activeTool = nil
        closeOptions()

        dragMode = .creating
        dragStart = point
        dragOffset = .zero
        selectionCG = CGRect(origin: point, size: .zero)
        state = .selecting
        toolbar?.orderOut(nil)
        syncMarks()
        updateSelectionViews()
    }

    func overlayMouseDragged(_ view: OverlayView, globalPoint: NSPoint) {
        guard let screen = startScreen else { return }
        let point = Geometry.cgPoint(fromNS: globalPoint)
        let bounds = Geometry.cgRect(fromNS: screen.frame)

        switch dragMode {
        case .resizing(let edges):
            selectionCG = resizedSelection(from: resizeAnchor, edges: edges, to: point, within: bounds)
            setResizeCursor(edges)
        case .moving:
            let origin = CGPoint(x: point.x - dragOffset.width, y: point.y - dragOffset.height)
            selectionCG = CGRect(origin: origin, size: selectionCG.size).clampedInside(bounds)
            NSCursor.closedHand.set()
        case .drawing:
            updateDrawing(in: view, globalPoint: globalPoint)
            return
        case .movingMark:
            moveSelectedMark(in: view, globalPoint: globalPoint)
        case .creating:
            guard state == .selecting else { return }
            selectionCG = CGRect(
                x: min(dragStart.x, point.x),
                y: min(dragStart.y, point.y),
                width: abs(point.x - dragStart.x),
                height: abs(point.y - dragStart.y)
            ).intersection(bounds)
        case .none:
            return
        }
        updateSelectionViews()
    }

    func overlayMouseUp(_ view: OverlayView, globalPoint: NSPoint) {
        let mode = dragMode
        dragMode = .none

        if case .drawing = mode {
            finishDrawing()
            return
        }

        if case .movingMark = mode {
            if markDragMoved, let moveHistory {
                pushHistory(moveHistory)
            }
            self.moveHistory = nil
            if !markDragMoved, let index = selectedMark, marks.indices.contains(index), case .text = marks[index] {
                beginText(at: viewPoint(view, globalPoint), in: view)
            }
            updateSelectionViews()
            showToolbar()
            return
        }

        if case .creating = mode {
            guard state == .selecting else { return }
            if selectionCG.width < SelectionController.minimumSelection
                || selectionCG.height < SelectionController.minimumSelection {
                cancel()
                return
            }
            state = .selected
            updateSelectionViews()
            showToolbar()
            return
        }

        guard state == .selected else { return }
        updateSelectionViews()
        showToolbar()
    }

    func overlayMouseMoved(_ view: OverlayView, globalPoint: NSPoint) {
        guard state == .selecting || state == .selected else { return }
        if state == .selected, dragMode == .none {
            switch selectionHit(at: Geometry.cgPoint(fromNS: globalPoint)) {
            case .resize(let edges):
                setResizeCursor(edges)
            case .move:
                if hitMark(at: viewPoint(view, globalPoint)) != nil {
                    NSCursor.openHand.set()
                } else if activeTool != nil {
                    toolCursor().set()
                } else {
                    NSCursor.openHand.set()
                }
            case .outside:
                NSCursor.crosshair.set()
            }
            return
        }
        NSCursor.crosshair.set()
    }

    func overlayDoubleClicked(_ view: OverlayView, globalPoint: NSPoint) {
        // With a drawing tool selected a double-click is part of the drawing,
        // not a request to copy.
        guard state == .selected, activeTool == nil else { return }
        guard selectionCG.width >= SelectionController.minimumSelection,
              selectionCG.height >= SelectionController.minimumSelection else { return }
        finishCopy()
    }

    func overlayRightClicked(_ view: OverlayView) {
        cancel()
    }

    // MARK: - Annotation

    private func toggleTool(_ tool: AnnotateTool) {
        commitText()
        if activeTool == tool {
            activeTool = nil
            closeOptions()
        } else {
            activeTool = tool
            showOptions(for: tool)
        }
        toolbar?.setActiveTool(activeTool)
        syncMarks()
    }

    private func showOptions(for tool: AnnotateTool) {
        if options == nil {
            let bar = ToolOptionsBar()
            bar.style = annotateStyle
            bar.onChange = { [weak self] in
                self?.applyStyleToTextField()
                self?.applyStyleToSelectedMark()
                self?.syncMarks()
            }
            bar.onGestureBegin = { [weak self] in self?.beginStyleGesture() }
            bar.onGestureEnd = { [weak self] in self?.endStyleGesture() }
            bar.onAutoMosaic = { [weak self] in self?.applyAutoMosaic() }
            bar.onClearMosaic = { [weak self] in self?.clearMosaics() }
            options = bar
        }
        options?.reload(tool: tool)
        positionOptions()
        options?.orderFrontRegardless()
    }

    private func closeOptions() {
        options?.orderOut(nil)
        options?.close()
        options = nil
    }

    private func positionOptions() {
        guard let options, let toolbar, let tool = activeTool, let screen = activeScreen,
              let anchor = toolbar.buttonScreenFrame(tool) else { return }
        let size = options.frame.size
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: toolbar.frame.minY - size.height - 2)
        var pointingUp = true
        if origin.y < screen.frame.minY + 4 {
            origin.y = toolbar.frame.maxY + 2
            pointingUp = false
        }
        origin.x = min(max(origin.x, screen.frame.minX + 4), screen.frame.maxX - size.width - 4)
        origin.y = min(max(origin.y, screen.frame.minY + 4), screen.frame.maxY - size.height - 4)
        options.setFrameOrigin(origin)
        options.placeCaret(x: anchor.midX - origin.x, pointingUp: pointingUp)
    }

    private func rendered(_ crop: CGImage) -> CGImage {
        commitText()
        guard !marks.isEmpty, let screen = activeScreen else { return crop }
        let selection = Geometry.nsRectInScreen(selectionCG, screen: screen)
        // Only mosaics read the frozen pixels; shapes and text must not pay
        // for a full-display buffer.
        let buffer = marks.contains(where: { $0.needsPixels }) ? ensurePixels() : nil
        return AnnotationDraw.composite(crop: crop, selection: selection, marks: marks, pixels: buffer) ?? crop
    }

    private func ensurePixels() -> PixelBuffer? {
        if let pixels { return pixels }
        guard let displayID = startDisplayID,
              let snap = snaps.first(where: { $0.displayID == displayID }),
              let screen = startScreen,
              let buffer = PixelBuffer(image: snap.image, viewSize: screen.frame.size) else { return nil }
        pixels = buffer
        return buffer
    }

    private func syncMarks() {
        let screen = activeScreen
        // Only mosaics need the display pixels, and that buffer is tens of
        // megabytes on a Retina screen.
        let needsPixels = marks.contains(where: { $0.needsPixels }) || (draft?.needsPixels ?? false)
        let buffer = needsPixels ? ensurePixels() : nil
        for entry in entries {
            let active = entry.screen === screen
            entry.view.annotationMarks = active ? marks : []
            entry.view.annotationDraft = active ? draft : nil
            entry.view.annotationPixels = active ? buffer : nil
            if active, let selectedMark, marks.indices.contains(selectedMark) {
                entry.view.annotationSelection = marks[selectedMark].bounds.insetBy(dx: -4, dy: -4)
                entry.view.hasAnnotationSelection = true
            } else {
                entry.view.hasAnnotationSelection = false
            }
            entry.view.needsDisplay = true
        }
    }

    private func viewPoint(_ view: OverlayView, _ global: NSPoint) -> NSPoint {
        guard let window = view.window else { return global }
        return view.convert(window.convertPoint(fromScreen: global), from: nil)
    }

    private func beginDrawing(in view: OverlayView, globalPoint: NSPoint) {
        guard let tool = activeTool else { return }
        selectedMark = nil
        let point = viewPoint(view, globalPoint)
        drawAnchor = point
        switch tool {
        case .text:
            beginText(at: point, in: view)
            return
        case .pen:
            draft = .pen([point], annotateStyle.stroke)
        case .arrow:
            draft = .arrow(point, point, annotateStyle.stroke)
        case .shape:
            if annotateStyle.shapeKind == .line {
                draft = .line(point, point, annotateStyle.stroke)
            } else {
                draft = .shape(annotateStyle.shapeKind, NSRect(origin: point, size: .zero), annotateStyle.stroke)
            }
        case .mosaic:
            guard annotateStyle.mosaicManual else { return }
            if annotateStyle.mosaicBrush {
                draft = .mosaicBrush([point], annotateStyle.mosaicPixel, annotateStyle.mosaicBlur)
            } else {
                draft = .mosaic(NSRect(origin: point, size: .zero), annotateStyle.mosaicPixel, annotateStyle.mosaicBlur)
            }
        }
        dragMode = .drawing
        toolCursor().set()
        syncMarks()
    }

    private func updateDrawing(in view: OverlayView, globalPoint: NSPoint) {
        let point = viewPoint(view, globalPoint)
        switch draft {
        case .pen(var points, let style):
            points.append(point)
            draft = .pen(points, style)
        case .arrow(let from, _, let style):
            draft = .arrow(from, point, style)
        case .line(let from, _, let style):
            draft = .line(from, point, style)
        case .shape(let kind, _, let style):
            draft = .shape(kind, NSRect(
                x: min(drawAnchor.x, point.x),
                y: min(drawAnchor.y, point.y),
                width: abs(point.x - drawAnchor.x),
                height: abs(point.y - drawAnchor.y)
            ), style)
        case .mosaicBrush(var points, let pixel, let blur):
            points.append(point)
            draft = .mosaicBrush(points, pixel, blur)
        case .mosaic:
            draft = .mosaic(NSRect(
                x: min(drawAnchor.x, point.x),
                y: min(drawAnchor.y, point.y),
                width: abs(point.x - drawAnchor.x),
                height: abs(point.y - drawAnchor.y)
            ), annotateStyle.mosaicPixel, annotateStyle.mosaicBlur)
        default:
            break
        }
        syncMarks()
    }

    private func finishDrawing() {
        if let draft, shouldCommit(draft) {
            pushHistory(currentHistory())
            marks.append(draft)
            selectedMark = marks.count - 1
        }
        self.draft = nil
        syncMarks()
    }

    private func shouldCommit(_ mark: AnnotationMark) -> Bool {
        switch mark {
        case .shape(_, let rect, _):
            return rect.width >= 2 || rect.height >= 2
        case .line(let from, let to, _), .arrow(let from, let to, _):
            return hypot(to.x - from.x, to.y - from.y) >= 2
        case .pen(let points, _):
            return !points.isEmpty
        case .mosaic(let rect, _, _):
            return rect.width >= 4 && rect.height >= 4
        case .mosaicBrush(let points, _, _):
            return !points.isEmpty
        case .text:
            return true
        }
    }

    private func applyAutoMosaic() {
        guard let screen = activeScreen else { return }
        let rect = Geometry.nsRectInScreen(selectionCG, screen: screen)
        pushHistory(currentHistory())
        marks.removeAll { mark in
            if case .mosaic = mark { return true }
            return false
        }
        marks.append(.mosaic(rect, annotateStyle.mosaicPixel, annotateStyle.mosaicBlur))
        syncMarks()
    }

    private func clearMosaics() {
        let hasMosaic = marks.contains { mark in
            switch mark {
            case .mosaic, .mosaicBrush: return true
            default: return false
            }
        }
        guard hasMosaic else { return }
        pushHistory(currentHistory())
        marks.removeAll { mark in
            switch mark {
            case .mosaic, .mosaicBrush: return true
            default: return false
            }
        }
        syncMarks()
    }

    private func beginText(at point: NSPoint, in view: OverlayView) {
        commitText()
        let before = currentHistory()
        if let existing = takeText(at: point) {
            textHistory = before
            openTextField(
                in: view,
                frame: existing.rect,
                string: existing.string,
                size: existing.size,
                color: existing.color,
                background: existing.background
            )
            return
        }
        let size = annotateStyle.textSize
        let frame = NSRect(x: point.x, y: point.y - size * 0.25, width: max(120, size * 4), height: size * 1.35)
        openTextField(
            in: view,
            frame: frame,
            string: "",
            size: size,
            color: annotateStyle.color,
            background: annotateStyle.textBackground
        )
    }

    private func takeText(at point: NSPoint) -> (rect: NSRect, string: String, size: CGFloat, color: NSColor, background: NSColor?)? {
        for index in marks.indices.reversed() {
            guard case .text(let rect, let string, let size, let color, let background) = marks[index] else { continue }
            guard rect.insetBy(dx: -6, dy: -4).contains(point) else { continue }
            if selectedMark == index {
                selectedMark = nil
            } else if let selected = selectedMark, selected > index {
                selectedMark = selected - 1
            }
            marks.remove(at: index)
            syncMarks()
            return (rect, string, size, color, background)
        }
        return nil
    }

    private func openTextField(in view: OverlayView, frame: NSRect, string: String, size: CGFloat, color: NSColor, background: NSColor?) {
        let field = NSTextField(frame: frame)
        field.font = NSFont.systemFont(ofSize: size, weight: .medium)
        field.textColor = color
        field.stringValue = string
        field.backgroundColor = background ?? .clear
        field.drawsBackground = background != nil
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.delegate = self
        if string.isEmpty {
            field.placeholderString = "输入文字"
        }
        view.addSubview(field)
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (string as NSString).length, length: 0)
        textField = field
        textHost = view
    }

    private func hitMark(at point: NSPoint) -> Int? {
        for index in marks.indices.reversed() where marks[index].hit(point) {
            return index
        }
        return nil
    }

    private func beginMovingMark(_ index: Int, at point: NSPoint) {
        selectedMark = index
        moveHistory = currentHistory()
        markDragOrigin = marks[index]
        markDragAnchor = point
        markDragMoved = false
        dragMode = .movingMark
        adoptStyle(from: marks[index])
        syncMarks()
    }

    private func moveSelectedMark(in view: OverlayView, globalPoint: NSPoint) {
        guard let index = selectedMark, let origin = markDragOrigin, marks.indices.contains(index) else { return }
        let point = viewPoint(view, globalPoint)
        let dx = point.x - markDragAnchor.x
        let dy = point.y - markDragAnchor.y
        if hypot(dx, dy) > 2 { markDragMoved = true }
        marks[index] = origin.translated(dx: dx, dy: dy)
        syncMarks()
    }

    private func adoptStyle(from mark: AnnotationMark) {
        switch mark {
        case .shape(_, _, let style), .line(_, _, let style), .arrow(_, _, let style), .pen(_, let style):
            annotateStyle.color = style.color
            annotateStyle.lineWidth = style.width
            annotateStyle.filled = style.filled
        case .text(_, _, let size, let color, let background):
            annotateStyle.color = color
            annotateStyle.textSize = size
            annotateStyle.textBackground = background
        default:
            return
        }
        guard let tool = tool(matching: mark) else { return }
        activeTool = tool
        toolbar?.setActiveTool(tool)
        showOptions(for: tool)
    }

    private func applyStyleToSelectedMark() {
        guard let index = selectedMark, marks.indices.contains(index) else { return }
        guard tool(matching: marks[index]) == activeTool else { return }
        if styleHistory == nil {
            styleHistory = currentHistory()
        }
        marks[index] = marks[index].applying(annotateStyle)
        if !styleGesture {
            sealStyleHistory()
        }
    }

    private func beginStyleGesture() {
        styleGesture = true
        guard styleHistory == nil else { return }
        guard let index = selectedMark, marks.indices.contains(index),
              tool(matching: marks[index]) == activeTool else { return }
        styleHistory = currentHistory()
    }

    private func endStyleGesture() {
        styleGesture = false
        sealStyleHistory()
    }

    private func tool(matching mark: AnnotationMark) -> AnnotateTool? {
        switch mark {
        case .shape, .line: return .shape
        case .arrow: return .arrow
        case .pen: return .pen
        case .text: return .text
        default: return nil
        }
    }

    private func applyStyleToTextField() {
        guard let field = textField else { return }
        field.font = NSFont.systemFont(ofSize: annotateStyle.textSize, weight: .medium)
        field.textColor = annotateStyle.color
        field.backgroundColor = annotateStyle.textBackground ?? .clear
        field.drawsBackground = annotateStyle.textBackground != nil
        var frame = field.frame
        frame.size.height = annotateStyle.textSize * 1.35
        field.frame = frame
    }

    private func commitText() {
        guard let field = textField else { return }
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let beforeEdit = textHistory
        textHistory = nil
        if !string.isEmpty {
            if let beforeEdit {
                pushHistory(beforeEdit)
            } else {
                pushHistory(currentHistory())
            }
            let size = field.font?.pointSize ?? annotateStyle.textSize
            let color = field.textColor ?? annotateStyle.color
            let background = field.drawsBackground ? field.backgroundColor : nil
            marks.append(.text(field.frame, string, size, color, background))
            selectedMark = marks.count - 1
        } else if let beforeEdit {
            pushHistory(beforeEdit)
        }
        removeTextField()
        syncMarks()
    }

    private struct MarkHistory {
        var marks: [AnnotationMark]
        var selected: Int?
    }

    private func currentHistory() -> MarkHistory {
        MarkHistory(marks: marks, selected: selectedMark)
    }

    private func pushHistory(_ entry: MarkHistory) {
        markHistory.append(entry)
        if markHistory.count > 40 {
            markHistory.removeFirst()
        }
        toolbar?.setUndoEnabled(true)
    }

    private func clearHistory() {
        markHistory.removeAll()
        moveHistory = nil
        textHistory = nil
        styleHistory = nil
        styleGesture = false
        toolbar?.setUndoEnabled(false)
    }

    private func sealStyleHistory() {
        guard let saved = styleHistory else { return }
        styleHistory = nil
        pushHistory(saved)
    }

    /// Puts the annotations back to where they were before the last completed
    /// stroke, move, restyle, mosaic or text edit. An open text field is
    /// committed first, so one undo drops that edit.
    private func undoAnnotation() {
        endStyleGesture()
        commitText()
        guard state == .selected, let entry = markHistory.popLast() else {
            toolbar?.setUndoEnabled(!markHistory.isEmpty)
            return
        }
        marks = entry.marks
        selectedMark = entry.selected
        draft = nil
        moveHistory = nil
        textHistory = nil
        syncMarks()
        toolbar?.setUndoEnabled(!markHistory.isEmpty)
    }

    private func removeTextField() {
        textField?.removeFromSuperview()
        textField = nil
        textHost = nil
    }

    private func toolCursor() -> NSCursor {
        activeTool == .text ? .iBeam : .crosshair
    }

    private enum SelectionHit {
        case resize(ResizeEdges)
        case move
        case outside
    }

    /// Corners first, then the four sides, then the inside of the rectangle.
    private func selectionHit(at point: CGPoint) -> SelectionHit {
        let rect = selectionCG
        guard rect.width >= 1, rect.height >= 1 else { return .outside }

        let cornerReach: CGFloat = 12
        let edgeReach: CGFloat = 7
        let corners: [(CGPoint, ResizeEdges)] = [
            (CGPoint(x: rect.minX, y: rect.minY), [.left, .top]),
            (CGPoint(x: rect.maxX, y: rect.minY), [.right, .top]),
            (CGPoint(x: rect.minX, y: rect.maxY), [.left, .bottom]),
            (CGPoint(x: rect.maxX, y: rect.maxY), [.right, .bottom])
        ]
        for (corner, edges) in corners {
            if hypot(point.x - corner.x, point.y - corner.y) <= cornerReach {
                return .resize(edges)
            }
        }

        let withinX = point.x >= rect.minX - edgeReach && point.x <= rect.maxX + edgeReach
        let withinY = point.y >= rect.minY - edgeReach && point.y <= rect.maxY + edgeReach
        if withinY && abs(point.x - rect.minX) <= edgeReach { return .resize(.left) }
        if withinY && abs(point.x - rect.maxX) <= edgeReach { return .resize(.right) }
        if withinX && abs(point.y - rect.minY) <= edgeReach { return .resize(.top) }
        if withinX && abs(point.y - rect.maxY) <= edgeReach { return .resize(.bottom) }
        if rect.contains(point) { return .move }
        return .outside
    }

    private func resizedSelection(from anchor: CGRect, edges: ResizeEdges, to point: CGPoint, within bounds: CGRect) -> CGRect {
        let minimum = SelectionController.minimumSelection
        var minX = anchor.minX
        var maxX = anchor.maxX
        var minY = anchor.minY
        var maxY = anchor.maxY

        if edges.contains(.left) { minX = min(point.x, anchor.maxX - minimum) }
        if edges.contains(.right) { maxX = max(point.x, anchor.minX + minimum) }
        if edges.contains(.top) { minY = min(point.y, anchor.maxY - minimum) }
        if edges.contains(.bottom) { maxY = max(point.y, anchor.minY + minimum) }

        minX = max(minX, bounds.minX)
        maxX = min(maxX, bounds.maxX)
        minY = max(minY, bounds.minY)
        maxY = min(maxY, bounds.maxY)

        if maxX - minX < minimum {
            if edges.contains(.left) {
                minX = max(bounds.minX, maxX - minimum)
            } else {
                maxX = min(bounds.maxX, minX + minimum)
            }
        }
        if maxY - minY < minimum {
            if edges.contains(.top) {
                minY = max(bounds.minY, maxY - minimum)
            } else {
                maxY = min(bounds.maxY, minY + minimum)
            }
        }

        return CGRect(x: minX, y: minY, width: max(minimum, maxX - minX), height: max(minimum, maxY - minY))
    }

    private func setResizeCursor(_ edges: ResizeEdges) {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch edges {
            case [.left, .top]: position = .topLeft
            case [.right, .top]: position = .topRight
            case [.left, .bottom]: position = .bottomLeft
            case [.right, .bottom]: position = .bottomRight
            case [.left], [.right]:
                NSCursor.resizeLeftRight.set()
                return
            default:
                NSCursor.resizeUpDown.set()
                return
            }
            NSCursor.frameResize(position: position, directions: .outward).set()
        } else if edges.contains(.left) || edges.contains(.right) {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.resizeUpDown.set()
        }
    }
}

private extension CGRect {
    /// Moves the rectangle so it stays inside `bounds` without changing its size.
    func clampedInside(_ bounds: CGRect) -> CGRect {
        var rect = self
        let maxX = max(bounds.minX, bounds.maxX - rect.width)
        let maxY = max(bounds.minY, bounds.maxY - rect.height)
        rect.origin.x = min(max(rect.origin.x, bounds.minX), maxX)
        rect.origin.y = min(max(rect.origin.y, bounds.minY), maxY)
        return rect
    }
}

extension SelectionController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commitText()
            return true
        }
        return false
    }
}
