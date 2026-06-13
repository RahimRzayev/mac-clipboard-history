import Foundation

/// App-wide runtime state driving the menu bar icon and capture gating.
@MainActor
final class AppState: ObservableObject {
    @Published var capturePaused = false
    @Published var privacyState: PasteboardAccessState = .notApplicable
    @Published var secureInputStuck = false

    /// Capture blocked by the system rather than the user (spec §4.2, §6.2):
    /// pasteboard access denied, or secure input stuck on.
    var captureBlocked: Bool {
        privacyState == .denied || secureInputStuck
    }

    var isCaptureEffectivelyActive: Bool {
        !capturePaused && !captureBlocked
    }
}
