import Foundation
import ServiceManagement

/// Login-item switch backed by SMAppService. The app must be code signed for
/// the registration to be accepted, which the build script does ad hoc.
enum LoginItem {

    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// Returns false when the system refused the registration.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}
