import AppKit
import ApplicationServices

/// Permission helpers for auto-paste (synthetic Cmd+V) and caret-position lookup.
/// Both surface under System Settings → Privacy & Security → Accessibility.
enum AccessibilityPermission {
    /// Can we post synthetic keyboard events? (The modern post-event TCC check, spec §11.)
    static var canPostEvents: Bool {
        CGPreflightPostEventAccess()
    }

    /// Can we read AX attributes (used for caret-position panel placement, spec §9)?
    static var isTrustedForAX: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system permission request. Called only in context — never at first
    /// launch (spec §11): from onboarding's optional step or the first paste attempt.
    @discardableResult
    static func requestPostEventAccess() -> Bool {
        CGRequestPostEventAccess()
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    static func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
