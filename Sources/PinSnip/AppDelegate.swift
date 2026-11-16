import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppEnvironment.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Nothing survives a quit: pins are memory only.
        AppEnvironment.shared.pins.closeAll()
        AppEnvironment.shared.selection.cancel()
    }
}
