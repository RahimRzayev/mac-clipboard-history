import Foundation

enum PanelPlacement: String, CaseIterable, Identifiable {
    /// Caret → mouse pointer → screen center cascade (spec §9).
    case auto
    case center

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Near text caret (recommended)"
        case .center: return "Center of screen"
        }
    }
}

/// User preferences. UserDefaults is for settings ONLY — never history (spec §2.4).
final class SettingsStore: ObservableObject {
    /// Default excluded apps: known password managers (spec §6.3). Every ID verified
    /// against App Store / Homebrew cask metadata (June 2026) — incl. non-obvious
    /// Catalyst IDs (Dashlane, KeePassium) and legacy IDs for old installs.
    /// NOTE: this is structurally blind to browser-EXTENSION copies (frontmost app is
    /// the browser) — SensitiveTextDetector is the layer that covers those.
    static let defaultExcludedBundleIDs: [String] = [
        // Apple
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        // 1Password
        "com.1password.1password",
        "com.1password.safari",
        "com.agilebits.onepassword7",
        // Bitwarden
        "com.bitwarden.desktop",
        "com.bitwarden.desktop.helper",
        // Dashlane (Catalyst — keeps its iOS-era ID)
        "com.dashlane.dashlanephonefinal",
        // LastPass (current desktop, Safari extension, legacy MAS)
        "com.lastpass.lastpassmacdesktop",
        "com.lastpass.lastpassforsafari",
        "com.lastpass.LastPass",
        // KeePass family
        "org.keepassxc.keepassxc",
        "com.keepassium.ios",
        "com.keepassium.ios.pro",
        // Keeper (cask / MAS / Safari host)
        "com.keepersecurity.passwordmanager",
        "com.callpod.keepermac.lite",
        "com.keepersecurity.safari.keeperfill",
        // NordPass (vendor prefix is nordsec; MAS sibling differs)
        "com.nordsec.nordpass",
        "com.nordsec.nordpass.safari.extension",
        "com.nordpass.safari.app.password.manager",
        // Proton Pass
        "me.proton.pass.electron",
        "me.proton.pass.catalyst",
        // Enpass
        "in.sinew.Enpass-Desktop",
        // RoboForm
        "com.sibersystems.RoboFormMac",
        // Strongbox (five SKUs)
        "com.markmcguill.strongbox",
        "com.markmcguill.strongbox.pro",
        "com.markmcguill.strongbox.mac",
        "com.markmcguill.strongbox.mac.pro",
        "com.markmcguill.strongbox.graphene",
        // Norton (Safari host app for Norton Password Manager; no desktop vault exists)
        "com.symantec.NortonPasswordManager.combined",
    ]

    static let maxItemsOptions = [100, 250, 500, 1000, 2000]
    static let maxItemSizeOptions: [(bytes: Int, label: String)] = [
        (100_000, "100 KB"),
        (1_000_000, "1 MB"),
        (5_000_000, "5 MB"),
    ]
    /// 0 = never.
    static let retentionOptions: [(days: Int, label: String)] = [
        (1, "1 day"),
        (7, "7 days"),
        (30, "30 days"),
        (90, "90 days"),
        (365, "1 year"),
        (0, "Never"),
    ]

    private enum Keys {
        static let monitoringEnabled = "monitoringEnabled"
        static let maxItems = "maxItems"
        static let maxItemSizeBytes = "maxItemSizeBytes"
        static let retentionDays = "retentionDays"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let skipPasswordLikeText = "skipPasswordLikeText"
        static let placement = "panelPlacement"
        static let firstRunCompleted = "firstRunCompleted"
    }

    private let defaults: UserDefaults

    @Published var monitoringEnabled: Bool {
        didSet { defaults.set(monitoringEnabled, forKey: Keys.monitoringEnabled) }
    }
    @Published var maxItems: Int {
        didSet { defaults.set(maxItems, forKey: Keys.maxItems) }
    }
    @Published var maxItemSizeBytes: Int {
        didSet { defaults.set(maxItemSizeBytes, forKey: Keys.maxItemSizeBytes) }
    }
    @Published var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Keys.retentionDays) }
    }
    @Published var excludedBundleIDs: [String] {
        didSet { defaults.set(excludedBundleIDs, forKey: Keys.excludedBundleIDs) }
    }
    @Published var skipPasswordLikeText: Bool {
        didSet { defaults.set(skipPasswordLikeText, forKey: Keys.skipPasswordLikeText) }
    }
    @Published var placement: PanelPlacement {
        didSet { defaults.set(placement.rawValue, forKey: Keys.placement) }
    }
    @Published var firstRunCompleted: Bool {
        didSet { defaults.set(firstRunCompleted, forKey: Keys.firstRunCompleted) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.monitoringEnabled: true,
            Keys.maxItems: 500,
            Keys.maxItemSizeBytes: 1_000_000,
            Keys.retentionDays: 30,
            Keys.excludedBundleIDs: Self.defaultExcludedBundleIDs,
            Keys.skipPasswordLikeText: true,
            Keys.placement: PanelPlacement.auto.rawValue,
            Keys.firstRunCompleted: false,
        ])
        monitoringEnabled = defaults.bool(forKey: Keys.monitoringEnabled)
        maxItems = defaults.integer(forKey: Keys.maxItems)
        maxItemSizeBytes = defaults.integer(forKey: Keys.maxItemSizeBytes)
        retentionDays = defaults.integer(forKey: Keys.retentionDays)
        excludedBundleIDs = defaults.stringArray(forKey: Keys.excludedBundleIDs) ?? Self.defaultExcludedBundleIDs
        skipPasswordLikeText = defaults.bool(forKey: Keys.skipPasswordLikeText)
        placement = PanelPlacement(rawValue: defaults.string(forKey: Keys.placement) ?? "") ?? .auto
        firstRunCompleted = defaults.bool(forKey: Keys.firstRunCompleted)
    }
}
