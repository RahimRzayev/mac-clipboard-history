import AppKit

/// Owns the previously-frontmost-app contract (spec §3, §10): captures the active app at
/// hotkey time — before the panel appears — and re-validates/restores it before auto-paste.
@MainActor
final class FocusTracker {
    private(set) var capturedApp: NSRunningApplication?

    /// Call when the hotkey fires, BEFORE showing the panel.
    func captureFrontmost() {
        capturedApp = NSWorkspace.shared.frontmostApplication
    }

    func clear() {
        capturedApp = nil
    }

    /// Confirms the target is frontmost; re-activates it if focus was lost (e.g. the user
    /// clicked the menu bar icon). Polls briefly because activation is asynchronous.
    ///
    /// Deliberately NO synchronous already-active fast path: confirmation always waits at
    /// least one poll cycle (~50ms) so key focus settles after the panel orders out.
    /// Posting Cmd+V in the same main-thread turn as orderOut races focus restoration and
    /// intermittently drops the paste into the just-hidden panel.
    func ensureFrontmost(_ target: NSRunningApplication, completion: @escaping (Bool) -> Void) {
        if target.isTerminated {
            completion(false)
            return
        }
        if !target.isActive {
            target.activate()
        }

        var attempts = 0
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            Task { @MainActor in
                // invalidate() cannot dequeue Tasks already enqueued by earlier fires
                // (e.g. after a nested run loop drained several at once) — bail so
                // completion runs exactly once and Cmd+V is never posted twice.
                guard timer.isValid else { return }
                attempts += 1
                if target.isActive {
                    timer.invalidate()
                    completion(true)
                } else if attempts >= 20 { // ~1s timeout
                    timer.invalidate()
                    completion(false)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
