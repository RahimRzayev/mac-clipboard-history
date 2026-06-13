import KeyboardShortcuts
import SwiftUI

struct SettingsActions {
    var clearHistory: (_ includePinned: Bool) -> Void = { _ in }
}

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var appState: AppState
    let actions: SettingsActions

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ClipboardSettingsTab()
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            PrivacySettingsTab(actions: actions)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            ShortcutSettingsTab()
                .tabItem { Label("Shortcut", systemImage: "keyboard") }
        }
        .frame(width: 500, height: 420)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var launchAtLogin = LaunchAtLoginHelper.isEnabled
    @State private var launchAtLoginError = false

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    if !LaunchAtLoginHelper.setEnabled(newValue) {
                        launchAtLogin = LaunchAtLoginHelper.isEnabled
                        launchAtLoginError = true
                    }
                }
            if launchAtLoginError {
                Text("Could not change the login item. This only works when running from the built .app bundle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Panel position", selection: $settings.placement) {
                ForEach(PanelPlacement.allCases) { placement in
                    Text(placement.label).tag(placement)
                }
            }

            Section {
                Text("Clipboard History lives in the menu bar — there is no Dock icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Clipboard

private struct ClipboardSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Toggle("Enable clipboard monitoring", isOn: $settings.monitoringEnabled)

            Picker("Maximum history items", selection: $settings.maxItems) {
                ForEach(SettingsStore.maxItemsOptions, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }

            Picker("Maximum text size", selection: $settings.maxItemSizeBytes) {
                ForEach(SettingsStore.maxItemSizeOptions, id: \.bytes) { option in
                    Text(option.label).tag(option.bytes)
                }
            }

            Section("Images & files") {
                Toggle("Save copied images", isOn: $settings.captureImages)
                Picker("Maximum image size", selection: $settings.maxImageSizeBytes) {
                    ForEach(SettingsStore.maxImageSizeOptions, id: \.bytes) { option in
                        Text(option.label).tag(option.bytes)
                    }
                }
                .disabled(!settings.captureImages)

                Toggle("Save copied files", isOn: $settings.captureFiles)
                Picker("Maximum file size", selection: $settings.maxFileSizeBytes) {
                    ForEach(SettingsStore.maxFileSizeOptions, id: \.bytes) { option in
                        Text(option.label).tag(option.bytes)
                    }
                }
                .disabled(!settings.captureFiles)
            }

            Section {
                Text("Pinned items are never removed by the item limit. Images and files are stored encrypted on disk, the same as text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Privacy

private struct PrivacySettingsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var appState: AppState
    let actions: SettingsActions

    @State private var newBundleID = ""
    @State private var selectedBundleID: String?
    @State private var showClearConfirmation = false

    var body: some View {
        Form {
            Toggle("Pause clipboard capture", isOn: $appState.capturePaused)

            Toggle("Skip text that looks like a password", isOn: $settings.skipPasswordLikeText)
            Text("Catches password-manager browser extensions (Norton, 1Password, Bitwarden…), which don't mark their copies as confidential. May occasionally skip password-shaped tokens such as generated API keys.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Auto-delete items after", selection: $settings.retentionDays) {
                ForEach(SettingsStore.retentionOptions, id: \.days) { option in
                    Text(option.label).tag(option.days)
                }
            }

            if appState.privacyState == .denied || appState.privacyState == .willAsk {
                Section {
                    Label(
                        appState.privacyState == .denied
                            ? "macOS is blocking pasteboard access for this app."
                            : "macOS may ask before this app can read the pasteboard.",
                        systemImage: "exclamationmark.triangle"
                    )
                    Button("Open System Settings → Paste from Other Apps") {
                        PasteboardPrivacy.openSystemSettings()
                    }
                }
            }

            Section("Excluded apps") {
                List(selection: $selectedBundleID) {
                    ForEach(settings.excludedBundleIDs, id: \.self) { bundleID in
                        Text(bundleID).tag(bundleID)
                    }
                }
                .frame(minHeight: 80)
                HStack {
                    TextField("Bundle identifier (e.g. com.example.app)", text: $newBundleID)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let trimmed = newBundleID.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, !settings.excludedBundleIDs.contains(trimmed) else { return }
                        settings.excludedBundleIDs.append(trimmed)
                        newBundleID = ""
                    }
                    Button("Remove") {
                        if let selectedBundleID {
                            settings.excludedBundleIDs.removeAll { $0 == selectedBundleID }
                        }
                        selectedBundleID = nil
                    }
                    .disabled(selectedBundleID == nil)
                }
            }

            Section {
                Button("Clear History…", role: .destructive) {
                    showClearConfirmation = true
                }
                Text("Clipboard history may contain sensitive copied text. Items marked confidential by password managers are never saved — but passwords copied via browser extensions may not be marked. Use Pause or excluded apps when needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog(
            "Clear clipboard history?",
            isPresented: $showClearConfirmation
        ) {
            Button("Clear, keep pinned items") {
                actions.clearHistory(false)
            }
            Button("Clear everything including pinned", role: .destructive) {
                actions.clearHistory(true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("History is deleted and the encryption key is rotated, so cleared data is unrecoverable.")
        }
    }
}

// MARK: - Shortcut

private struct ShortcutSettingsTab: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Open clipboard history:", name: .togglePanel)
            Section {
                Text("The default is ⇧⌘C. Avoid ⇧⌘V — most apps use it for “Paste and Match Style”, and a global shortcut would block it everywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
