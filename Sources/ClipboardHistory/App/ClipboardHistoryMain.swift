import AppKit

// Menu bar utility: AppKit lifecycle (spec §3). LSUIElement in Info.plist hides the Dock
// icon for the bundled app; .accessory covers `swift run` during development.
@main
@MainActor
enum ClipboardHistoryMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
