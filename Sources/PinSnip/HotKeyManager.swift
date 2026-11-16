import Carbon
import Foundation

/// Global hotkeys registered with the system hotkey API (Carbon), so they
/// fire while another application is frontmost.
final class HotKeyManager {

    enum Tag: UInt32 {
        case capture = 1
        case paste = 2
        case hideAll = 3
    }

    /// Four-char signature used in EventHotKeyID.
    private static let signature: UInt32 = 0x5049_4E53 // "PINS"

    private var handlerRef: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var installed = false

    // MARK: - Event handler

    func install() {
        guard !installed else { return }
        installed = true

        var type = EventTypeSpec()
        type.eventClass = OSType(kEventClassKeyboard)
        type.eventKind = UInt32(kEventHotKeyPressed)

        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData = userData, let event = event else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            return manager.handle(event)
        }

        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &type,
            Unmanaged.passUnretained(self).toOpaque(),
            &ref
        )
        if status == noErr {
            handlerRef = ref
        } else {
            installed = false
        }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            Int(MemoryLayout<EventHotKeyID>.size),
            nil,
            &hotKeyID
        )
        guard status == noErr, let action = actions[hotKeyID.id] else { return noErr }
        DispatchQueue.main.async { action() }
        return noErr
    }

    // MARK: - Registration

    /// Returns false when the system reports the combination is already taken.
    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        unregister(id: id)

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotKeyManager.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let registered = ref else {
            return false
        }
        refs[id] = registered
        actions[id] = action
        return true
    }

    @discardableResult
    func register(tag: Tag, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        register(id: tag.rawValue, keyCode: keyCode, modifiers: modifiers, action: action)
    }

    func unregister(id: UInt32) {
        if let ref = refs[id] {
            UnregisterEventHotKey(ref)
            refs[id] = nil
        }
        actions[id] = nil
    }

    func unregister(tag: Tag) {
        unregister(id: tag.rawValue)
    }

    func unregisterAll() {
        for ref in refs.values {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        actions.removeAll()
    }

    /// Re-register every combination in one pass. Returns the tags that the
    /// system refused, so the caller can tell the user which group is taken.
    @discardableResult
    func registerAll(
        _ entries: [(tag: Tag, keyCode: UInt32, modifiers: UInt32, action: () -> Void)]
    ) -> [Tag] {
        var failed: [Tag] = []
        for (tag, keyCode, modifiers, action) in entries {
            if !register(tag: tag, keyCode: keyCode, modifiers: modifiers, action: action) {
                failed.append(tag)
            }
        }
        return failed
    }
}
