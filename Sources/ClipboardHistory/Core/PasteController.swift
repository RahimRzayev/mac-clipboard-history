import AppKit
import Carbon.HIToolbox

enum PasteOutcome {
    case pasted
    case copiedOnly(CopyOnlyReason)

    enum CopyOnlyReason {
        case noAccessibilityPermission
        case secureInputActive
        case targetAppUnavailable
    }
}

/// Restores items to the pasteboard and performs auto-paste via a synthesized Cmd+V.
/// Owns self-write suppression: the watcher asks us whether a changeCount was ours (spec §3).
@MainActor
final class PasteController {
    private let pasteboard = NSPasteboard.general
    private let secureInput: SecureInputMonitor
    private(set) var suppressedChangeCount: Int = -1

    init(secureInput: SecureInputMonitor) {
        self.secureInput = secureInput
    }

    func isOwnWrite(changeCount: Int) -> Bool {
        changeCount == suppressedChangeCount
    }

    /// Writes content back to the system pasteboard, marked with org.nspasteboard.source
    /// per the nspasteboard.org convention (spec §6.5), and records the resulting
    /// changeCount so the watcher ignores this write (spec §5.1).
    func copyToPasteboard(_ content: String) {
        pasteboard.declareTypes([.string, Self.sourceMarkerType], owner: nil)
        pasteboard.setString(content, forType: .string)
        pasteboard.setString(Self.sourceIdentifier, forType: Self.sourceMarkerType)
        suppressedChangeCount = pasteboard.changeCount
    }

    /// Full paste sequence (spec §11): pasteboard write → focus re-validation → Cmd+V.
    /// `target` is the app FocusTracker captured at hotkey time, BEFORE the panel appeared.
    func paste(
        _ content: String,
        into target: NSRunningApplication?,
        focusTracker: FocusTracker,
        completion: @escaping (PasteOutcome) -> Void
    ) {
        copyToPasteboard(content)

        guard AccessibilityPermission.canPostEvents else {
            completion(.copiedOnly(.noAccessibilityPermission))
            return
        }
        // CGEvent posting silently fails under Secure Keyboard Entry — fall back loudly (spec §11).
        guard !secureInput.check().active else {
            completion(.copiedOnly(.secureInputActive))
            return
        }
        guard let target else {
            completion(.copiedOnly(.targetAppUnavailable))
            return
        }

        focusTracker.ensureFrontmost(target) { [weak self] success in
            guard success else {
                // Never paste into an unverified target (spec §11.4).
                completion(.copiedOnly(.targetAppUnavailable))
                return
            }
            self?.postCmdV()
            completion(.pasted)
        }
    }

    private func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }

    static let sourceMarkerType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    static var sourceIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.rahimrzayev.ClipboardHistory"
    }
}
