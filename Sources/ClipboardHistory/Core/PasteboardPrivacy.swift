import AppKit

/// macOS pasteboard privacy ("Paste from Other Apps", spec §4).
/// As of macOS 26.x the alert system is still opt-in (EnablePasteboardPrivacyDeveloperPreview),
/// but the accessBehavior API shipped in 15.4 and enforcement may flip in the macOS 27 cycle.
enum PasteboardAccessState: Equatable {
    /// Pre-15.4 macOS — the concept does not exist; behave normally.
    case notApplicable
    case allowed
    case willAsk
    case denied
}

enum PasteboardPrivacy {
    static func currentState() -> PasteboardAccessState {
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow:
                return .allowed
            case .ask:
                return .willAsk
            case .alwaysDeny:
                return .denied
            case .default:
                // System default: no per-app decision recorded. While enforcement is opt-in
                // this behaves as allow; under enforcement the first read would prompt.
                return .allowed
            @unknown default:
                return .allowed
            }
        }
        return .notApplicable
    }

    /// Deep link to System Settings → Privacy & Security → Paste from Other Apps.
    /// Note: the pane only appears after an app first triggers the permission request.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!

    static func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
