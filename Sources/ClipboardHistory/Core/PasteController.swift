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

    // MARK: - Pasteboard population (also the copy-only / Option+Enter path)

    /// Writes text back to the system pasteboard, marked with org.nspasteboard.source per the
    /// convention (spec §6.5), and records the resulting changeCount for self-write
    /// suppression (spec §5.1).
    func copyToPasteboard(_ content: String) {
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        pasteboard.setString(Self.sourceIdentifier, forType: Self.sourceMarkerType)
        suppressedChangeCount = pasteboard.changeCount
    }

    func copyImageToPasteboard(_ data: Data, uti: String) {
        pasteboard.clearContents()
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(uti))
        pasteboard.setString(Self.sourceIdentifier, forType: Self.sourceMarkerType)
        suppressedChangeCount = pasteboard.changeCount
    }

    /// Materializes file bytes into a per-paste temp dir and puts the file URLs on the
    /// pasteboard. Returns false (WITHOUT touching the pasteboard) if nothing could be
    /// materialized, so a disk error never wipes the user's current clipboard. Each file gets
    /// its own indexed subdirectory so same-named files don't collide. The temp dir is
    /// reclaimed on next launch (PasteController.cleanTempDirectory).
    @discardableResult
    func copyFilesToPasteboard(_ files: [(name: String, data: Data)]) -> Bool {
        let root = Self.tempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var urls: [NSURL] = []
        for (index, file) in files.enumerated() {
            let dir = root.appendingPathComponent("\(index)", isDirectory: true)
            guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
            else { continue }
            let url = dir.appendingPathComponent(file.name)
            if (try? file.data.write(to: url, options: [.atomic])) != nil {
                urls.append(url as NSURL)
            }
        }
        guard !urls.isEmpty else { return false } // leave the existing pasteboard untouched

        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
        pasteboard.setString(Self.sourceIdentifier, forType: Self.sourceMarkerType)
        suppressedChangeCount = pasteboard.changeCount
        return true
    }

    // MARK: - Paste (populate + auto-paste tail)

    func paste(text: String, into target: NSRunningApplication?, focusTracker: FocusTracker,
               completion: @escaping (PasteOutcome) -> Void) {
        copyToPasteboard(text)
        performPaste(into: target, focusTracker: focusTracker, completion: completion)
    }

    func paste(image data: Data, uti: String, into target: NSRunningApplication?,
               focusTracker: FocusTracker, completion: @escaping (PasteOutcome) -> Void) {
        copyImageToPasteboard(data, uti: uti)
        performPaste(into: target, focusTracker: focusTracker, completion: completion)
    }

    /// Returns false if the files couldn't be materialized (caller should report it and the
    /// pasteboard is left untouched). Otherwise runs the normal auto-paste tail.
    @discardableResult
    func paste(files: [(name: String, data: Data)], into target: NSRunningApplication?,
               focusTracker: FocusTracker, completion: @escaping (PasteOutcome) -> Void) -> Bool {
        guard copyFilesToPasteboard(files) else { return false }
        performPaste(into: target, focusTracker: focusTracker, completion: completion)
        return true
    }

    /// Shared tail (spec §11): assumes the pasteboard is already populated and
    /// suppressedChangeCount set. `target` is the app captured at hotkey time.
    private func performPaste(into target: NSRunningApplication?, focusTracker: FocusTracker,
                              completion: @escaping (PasteOutcome) -> Void) {
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

    /// Per-paste temp files for file paste-back live here; reclaimed at launch.
    static var tempDirectory: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.rahimrzayev.ClipboardHistory"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("paste-temp", isDirectory: true)
    }

    /// Materialized file bytes are a transient at-rest plaintext leak (the thing encryption
    /// exists to avoid) — wipe them at launch so they never linger.
    static func cleanTempDirectory() {
        try? FileManager.default.removeItem(at: tempDirectory)
    }
}
