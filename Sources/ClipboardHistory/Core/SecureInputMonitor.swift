import Carbon.HIToolbox
import Foundation

/// Wraps IsSecureEventInputEnabled() (spec §6.2): capture must skip while a secure text
/// field (password field, sudo prompt) has keyboard focus. Also tracks the well-known
/// "secure input stuck on" ecosystem issue so the menu bar icon can explain why capture
/// silently stopped.
final class SecureInputMonitor {
    /// How long continuous secure input must persist before we call it "stuck".
    private let stuckThreshold: TimeInterval

    private var activeSince: Date?

    init(stuckThreshold: TimeInterval = 60) {
        self.stuckThreshold = stuckThreshold
    }

    func check(now: Date = Date()) -> (active: Bool, stuck: Bool) {
        guard IsSecureEventInputEnabled() else {
            activeSince = nil
            return (false, false)
        }
        if activeSince == nil {
            activeSince = now
        }
        let stuck = now.timeIntervalSince(activeSince ?? now) >= stuckThreshold
        return (true, stuck)
    }
}
