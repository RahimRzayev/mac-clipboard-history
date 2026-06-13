import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Default is Cmd+Shift+C — deliberately NOT Cmd+Shift+V, which would shadow
    /// "Paste and Match Style" system-wide (spec §2.3). Customizable in Settings (v1).
    static let togglePanel = Self("togglePanel", default: .init(.c, modifiers: [.command, .shift]))
}

/// Thin wrapper over the KeyboardShortcuts package (Carbon RegisterEventHotKey underneath).
@MainActor
final class HotkeyManager {
    init(onToggle: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .togglePanel) {
            onToggle()
        }
    }

    var currentShortcutDescription: String {
        KeyboardShortcuts.getShortcut(for: .togglePanel)?.description ?? "⇧⌘C"
    }
}
