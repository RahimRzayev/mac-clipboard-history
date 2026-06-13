import AppKit
import SwiftUI

/// Hosts the popup in a non-activating floating NSPanel (spec §9): the frontmost app keeps
/// focus the entire time the panel is open, which is what makes auto-paste land in the
/// right place. A SwiftUI window would activate the app and break the core flow.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    /// Borderless windows refuse key status by default; the search field needs it.
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    static let panelSize = NSSize(width: 440, height: 560)

    private let panel: KeyablePanel
    private let viewModel: PanelViewModel
    private var keyMonitor: Any?
    private var isHiding = false

    var placement: () -> PanelPlacement = { .auto }

    init(viewModel: PanelViewModel) {
        self.viewModel = viewModel
        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        // Appears over full-screen apps and on every Space (spec §9).
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ClipboardPanelView(viewModel: viewModel))
    }

    var isVisible: Bool { panel.isVisible }

    /// Caller (AppDelegate) must capture the frontmost app via FocusTracker BEFORE this.
    func show() {
        viewModel.reset()
        let origin = PanelPositioner.origin(for: Self.panelSize, placement: placement())
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: false)
        installKeyMonitor()
        // Makes the panel key WITHOUT activating this app — the previously active app
        // stays frontmost (acceptance §16.5).
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard !isHiding else { return }
        isHiding = true
        defer { isHiding = false }
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    // Click outside the panel → it resigns key → dismiss.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: - Keyboard routing (spec §10)

    // The search field keeps focus permanently; navigation keys are intercepted here
    // before SwiftUI sees them. Everything unhandled falls through to the field.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        viewModel.isCmdHeld = false
    }

    /// Hardware keyCodes for the digit row 1–9 (ANSI positions — layout-independent,
    /// unlike characters, which break on AZERTY/Cyrillic layouts and under Caps Lock).
    private static let quickPasteKeyCodes: [UInt16: Int] = [
        18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8,
    ]

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard panel.isKeyWindow else { return event }

        if event.type == .flagsChanged {
            // Quick-paste badges show only while Cmd ALONE is held — also avoids the
            // badge flash while Shift from the ⇧⌘C hotkey chord is still down.
            viewModel.isCmdHeld =
                event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            return event
        }

        // IME composition: while marked text exists, Return commits the conversion, arrows
        // navigate candidates, and Escape cancels — those keys belong to the input method,
        // not to us. Swallowing them would paste a history item mid-composition.
        if let textView = panel.firstResponder as? NSTextView, textView.hasMarkedText() {
            return event
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 125: // down arrow
            viewModel.moveSelection(1)
            return nil
        case 126: // up arrow
            viewModel.moveSelection(-1)
            return nil
        case 36, 76: // return / keypad enter
            if flags.contains(.option) {
                viewModel.copySelectedOnly() // Option+Enter = copy without pasting
            } else {
                viewModel.confirmSelection()
            }
            return nil
        case 53: // escape — two-stage: clear query first, then close (spec §10)
            if viewModel.query.isEmpty {
                hide()
            } else {
                viewModel.query = ""
            }
            return nil
        case 51 where flags.contains(.command): // Cmd+Delete — plain Backspace only edits the query
            viewModel.deleteSelected()
            return nil
        case 35 where flags.contains(.command): // Cmd+P (keyCode, not character)
            viewModel.togglePinSelected()
            return nil
        default:
            break
        }

        if flags.contains(.command), let index = Self.quickPasteKeyCodes[event.keyCode] {
            viewModel.pasteVisibleIndex(index)
            return nil
        }
        return event
    }
}
