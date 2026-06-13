import Foundation
import ServiceManagement

/// Launch at login via SMAppService (macOS 13+, the modern API — spec v1's open question).
/// Status is user-visible under System Settings → General → Login Items.
/// Note: registration only works from a real .app bundle, not a bare `swift run` binary.
enum LaunchAtLoginHelper {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

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
