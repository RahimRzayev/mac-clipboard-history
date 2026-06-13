import AppKit
import Combine
import CryptoKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsStore!
    private let appState = AppState()
    private var store: ClipboardStore!
    private var watcher: ClipboardWatcher!
    private var pasteController: PasteController!
    private let focusTracker = FocusTracker()
    private var hotkeyManager: HotkeyManager!
    private var panelViewModel: PanelViewModel!
    private var panelController: PanelController!
    private var menuBar: MenuBarController!
    private let toast = ToastPresenter()
    private let secureInput = SecureInputMonitor()
    private var sourceTracker: SourceAppTracker!
    private var keyStore: KeychainKeyStore!
    private var encryption: EncryptionService!
    private var usingMemoryFallback = false

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var retentionTimer: Timer?
    private var privacyRecheckTimer: Timer?

    static let fallbackBundleID = "com.rahimrzayev.ClipboardHistory"

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = SettingsStore()
        sourceTracker = SourceAppTracker()
        appState.privacyState = PasteboardPrivacy.currentState()

        let storage = makeStorage()
        store = ClipboardStore(
            storage: storage,
            maxItems: { [weak self] in self?.settings.maxItems ?? 500 },
            retentionDays: { [weak self] in self?.settings.retentionDays ?? 30 },
            rotateEncryptionKey: { [weak self] in
                guard let self else { return }
                // In memory-fallback mode the on-disk database is intact but unreachable
                // this session — rotating the PERSISTENT key would orphan it forever.
                // Rotate only the ephemeral in-memory key instead.
                if self.usingMemoryFallback {
                    self.encryption.replaceKey(SymmetricKey(size: .bits256))
                    return
                }
                let newKey = try self.keyStore.rotateKey()
                self.encryption.replaceKey(newKey)
            }
        )

        pasteController = PasteController(secureInput: secureInput)
        setUpWatcher()
        setUpPanel()
        setUpMenuBar()

        hotkeyManager = HotkeyManager { [weak self] in
            self?.togglePanel()
        }

        // Settings/state changes drive the watcher timer and the menu bar icon.
        appState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.syncCaptureState() }
            }
            .store(in: &cancellables)
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.syncCaptureState() }
            }
            .store(in: &cancellables)

        // Retention purge at launch and periodically thereafter (spec §7).
        store.applyRetention()
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.store.applyRetention()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer

        // Periodically re-check pasteboard privacy so capture recovers when the user
        // re-allows access in System Settings (an accessBehavior read never alerts).
        let privacyTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let current = PasteboardPrivacy.currentState()
                if self.appState.privacyState != current {
                    self.appState.privacyState = current // drives syncCaptureState + icon
                }
            }
        }
        RunLoop.main.add(privacyTimer, forMode: .common)
        privacyRecheckTimer = privacyTimer

        syncCaptureState()

        if usingMemoryFallback {
            toast.show("Could not open the history database — history will not survive relaunch.", duration: 5)
        }
        if !settings.firstRunCompleted {
            showOnboarding()
        }
    }

    // Reopening the app (e.g. double-clicking it in Finder) surfaces Settings, since a
    // menu-bar-only app otherwise shows nothing (spec §12).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: - Construction

    private func makeStorage() -> ClipboardStorage {
        let bundleID = Bundle.main.bundleIdentifier ?? Self.fallbackBundleID
        keyStore = KeychainKeyStore(service: bundleID)
        do {
            let key = try keyStore.loadOrCreateKey()
            encryption = EncryptionService(key: key)
            let supportDir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(bundleID, isDirectory: true)
            return try SQLiteClipboardStorage(
                databaseURL: supportDir.appendingPathComponent("history.sqlite"),
                encryption: encryption
            )
        } catch {
            // Degraded mode: app stays usable, history just won't persist (spec §3 fallback).
            encryption = EncryptionService(key: SymmetricKey(size: .bits256))
            usingMemoryFallback = true
            return MemoryClipboardStorage()
        }
    }

    private func setUpWatcher() {
        watcher = ClipboardWatcher(secureInput: secureInput, sourceTracker: sourceTracker)
        watcher.isCaptureAllowed = { [weak self] in
            guard let self else { return false }
            return self.settings.monitoringEnabled && self.appState.isCaptureEffectivelyActive
        }
        watcher.shouldIgnoreChangeCount = { [weak self] count in
            self?.pasteController.isOwnWrite(changeCount: count) ?? false
        }
        watcher.excludedBundleIDs = { [weak self] in
            Set(self?.settings.excludedBundleIDs ?? [])
        }
        watcher.maxItemSizeBytes = { [weak self] in
            self?.settings.maxItemSizeBytes ?? 1_000_000
        }
        watcher.skipPasswordLikeText = { [weak self] in
            self?.settings.skipPasswordLikeText ?? true
        }
        watcher.onCapture = { [weak self] content, app in
            self?.store.capture(
                content: content,
                sourceBundleID: app?.bundleIdentifier,
                sourceAppName: app?.localizedName
            )
        }
        watcher.onSecureInputStuckChanged = { [weak self] stuck in
            guard let self, self.appState.secureInputStuck != stuck else { return }
            self.appState.secureInputStuck = stuck
        }
    }

    private func setUpPanel() {
        panelViewModel = PanelViewModel(store: store)
        panelViewModel.onPaste = { [weak self] item in self?.pasteItem(item) }
        panelViewModel.onCopyOnly = { [weak self] item in self?.copyItemOnly(item) }
        panelController = PanelController(viewModel: panelViewModel)
        panelController.placement = { [weak self] in self?.settings.placement ?? .auto }
    }

    private func setUpMenuBar() {
        menuBar = MenuBarController()
        menuBar.isPaused = { [weak self] in self?.appState.capturePaused ?? false }
        menuBar.isBlocked = { [weak self] in self?.appState.captureBlocked ?? false }
        menuBar.blockedExplanation = { [weak self] in
            guard let self else { return "" }
            if self.appState.privacyState == .denied {
                return "Capture blocked: pasteboard access denied in System Settings"
            }
            if self.appState.secureInputStuck {
                return "Capture blocked: another app is holding secure input"
            }
            return ""
        }
        menuBar.shortcutHint = { [weak self] in
            self?.hotkeyManager?.currentShortcutDescription ?? "⇧⌘C"
        }
        menuBar.onOpenHistory = { [weak self] in self?.togglePanel() }
        menuBar.onTogglePause = { [weak self] in self?.appState.capturePaused.toggle() }
        menuBar.onClearHistory = { [weak self] in self?.confirmClearHistory() }
        menuBar.onOpenSettings = { [weak self] in self?.showSettings() }
    }

    private func syncCaptureState() {
        // The timer is governed only by USER states (monitoring off, manual pause). While
        // system-blocked (privacy denied, secure input stuck) it keeps ticking — capture is
        // gated inside the pipeline — because the tick is what detects recovery from those
        // states. Stopping it there would make the blocked state permanent.
        let shouldRun = settings.monitoringEnabled && !appState.capturePaused
        if shouldRun && !watcher.isRunning {
            watcher.start()
        } else if !shouldRun && watcher.isRunning {
            watcher.stop()
        }

        if appState.captureBlocked {
            menuBar.setIcon(.blocked)
        } else if appState.capturePaused || !settings.monitoringEnabled {
            menuBar.setIcon(.paused)
        } else {
            menuBar.setIcon(.normal)
        }
    }

    // MARK: - Panel

    private func togglePanel() {
        // During a modal session (Clear History alert) the panel could be ordered front
        // but never become key (worksWhenModal is false) — it would appear keyboard-dead
        // with no way to dismiss it.
        guard NSApp.modalWindow == nil else {
            NSSound.beep()
            return
        }
        if panelController.isVisible {
            panelController.hide()
        } else {
            // Capture the frontmost app BEFORE the panel appears (spec §11.1).
            focusTracker.captureFrontmost()
            panelController.show()
        }
    }

    private func pasteItem(_ item: ClipboardItem) {
        let target = focusTracker.capturedApp
        panelController.hide()
        store.recordUse(of: item.id)

        // Permission is requested in context on first paste, never at launch (spec §11).
        if !AccessibilityPermission.canPostEvents {
            AccessibilityPermission.requestPostEventAccess()
        }

        pasteController.paste(item.content, into: target, focusTracker: focusTracker) { [weak self] outcome in
            switch outcome {
            case .pasted:
                break
            case .copiedOnly(let reason):
                let message: String
                switch reason {
                case .noAccessibilityPermission:
                    message = "Copied. Enable auto-paste in System Settings → Accessibility."
                case .secureInputActive:
                    message = "Copied. Auto-paste is unavailable while secure input is active — press ⌘V."
                case .targetAppUnavailable:
                    message = "Copied to clipboard — press ⌘V to paste."
                }
                self?.toast.show(message)
            }
        }
    }

    private func copyItemOnly(_ item: ClipboardItem) {
        panelController.hide()
        store.recordUse(of: item.id)
        pasteController.copyToPasteboard(item.content)
        toast.show("Copied to clipboard")
    }

    // MARK: - Menu actions

    private func confirmClearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "History is deleted and the encryption key is rotated, so cleared data is unrecoverable."
        alert.addButton(withTitle: "Clear, Keep Pinned")
        alert.addButton(withTitle: "Clear Everything")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            store.clearAll(includePinned: false)
        case .alertSecondButtonReturn:
            store.clearAll(includePinned: true)
        default:
            break
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(actions: SettingsActions(
                clearHistory: { [weak self] includePinned in
                    self?.store.clearAll(includePinned: includePinned)
                }
            ))
            .environmentObject(settings)
            .environmentObject(appState)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Clipboard History Settings"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showOnboarding() {
        let view = OnboardingView(
            privacyState: appState.privacyState,
            shortcutHint: hotkeyManager.currentShortcutDescription,
            onFinish: { [weak self] in
                self?.settings.firstRunCompleted = true
                self?.onboardingWindow?.orderOut(nil)
                self?.onboardingWindow = nil
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Clipboard History"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
