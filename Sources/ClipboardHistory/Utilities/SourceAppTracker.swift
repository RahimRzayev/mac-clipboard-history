import AppKit

/// Best-effort source-app attribution (spec §5). NSPasteboard exposes no public source API,
/// so we sample the frontmost app in the same tick the change is detected, with a small
/// timestamped record of recent activations to ride out fast app switches.
@MainActor
final class SourceAppTracker {
    private struct Activation {
        let app: NSRunningApplication
        let at: Date
    }

    private var recentActivations: [Activation] = []
    private var observer: NSObjectProtocol?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self?.record(app)
            }
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func record(_ app: NSRunningApplication) {
        recentActivations.append(Activation(app: app, at: Date()))
        if recentActivations.count > 10 {
            recentActivations.removeFirst(recentActivations.count - 10)
        }
    }

    /// The app most plausibly responsible for a pasteboard change detected "now":
    /// the current frontmost app, or — if the frontmost app activated only milliseconds ago
    /// (the user copied then instantly Cmd+Tabbed) — the previously active app.
    func bestGuessSourceApp(now: Date = Date()) -> NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let last = recentActivations.last,
           last.app.processIdentifier == frontmost?.processIdentifier,
           now.timeIntervalSince(last.at) < 0.25,
           recentActivations.count >= 2 {
            return recentActivations[recentActivations.count - 2].app
        }
        return frontmost
    }
}
