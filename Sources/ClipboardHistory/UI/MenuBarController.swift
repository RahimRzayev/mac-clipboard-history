import AppKit

/// NSStatusItem with three visually distinct states (spec §12): normal, manually paused,
/// and capture-blocked (privacy denied / secure input stuck) so users understand why
/// capture silently stopped.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    enum IconState {
        case normal
        case paused
        case blocked
    }

    private let statusItem: NSStatusItem

    var isPaused: () -> Bool = { false }
    var isBlocked: () -> Bool = { false }
    var blockedExplanation: () -> String = { "" }
    var shortcutHint: () -> String = { "⇧⌘C" }
    var onOpenHistory: () -> Void = {}
    var onTogglePause: () -> Void = {}
    var onClearHistory: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        setIcon(.normal)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func setIcon(_ state: IconState) {
        let symbolName: String
        let description: String
        switch state {
        case .normal:
            symbolName = "doc.on.clipboard"
            description = "Clipboard History"
        case .paused:
            symbolName = "pause.circle"
            description = "Clipboard History (paused)"
        case .blocked:
            symbolName = "exclamationmark.triangle"
            description = "Clipboard History (capture blocked)"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: description
        )
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = NSMenuItem(title: "Open Clipboard History", action: #selector(openHistory), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let hint = NSMenuItem(title: "Shortcut: \(shortcutHint())", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        if isBlocked() {
            let blocked = NSMenuItem(title: blockedExplanation(), action: nil, keyEquivalent: "")
            blocked.isEnabled = false
            menu.addItem(blocked)
        }

        let pauseTitle = isPaused() ? "Resume Clipboard Capture" : "Pause Clipboard Capture"
        let pause = NSMenuItem(title: pauseTitle, action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        let clear = NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Clipboard History",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
    }

    @objc private func openHistory() { onOpenHistory() }
    @objc private func togglePause() { onTogglePause() }
    @objc private func clearHistory() { onClearHistory() }
    @objc private func openSettings() { onOpenSettings() }
}
