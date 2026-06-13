import SwiftUI

/// First-run walkthrough (spec §13). Skippable; permissions are explained in context and
/// never demanded up front.
struct OnboardingView: View {
    let privacyState: PasteboardAccessState
    let shortcutHint: String
    var onFinish: () -> Void

    @State private var pageIndex = 0

    private var pages: [OnboardingPage] {
        var result: [OnboardingPage] = [
            OnboardingPage(
                icon: "doc.on.clipboard",
                title: "Clipboard History",
                body: "Everything you copy is saved locally — encrypted — and is one keystroke away. Unlike Spotlight's built-in clipboard history, items can be pinned forever, kept longer than 7 days, and pasted straight into the app you're working in."
            ),
            OnboardingPage(
                icon: "keyboard",
                title: "One shortcut",
                body: "Press \(shortcutHint) to open the history popup anywhere. Type to search, use ↑↓ to choose, and press Return to paste. You can change the shortcut in Settings."
            ),
        ]
        if privacyState == .willAsk || privacyState == .denied {
            result.append(OnboardingPage(
                icon: "hand.raised",
                title: "Pasteboard access",
                body: "macOS controls which apps may read the pasteboard. For clipboard history to work, set this app to “Allow” under System Settings → Privacy & Security → Paste from Other Apps. The system prompt only offers Allow/Deny — the permanent setting lives in System Settings.",
                buttonTitle: "Open System Settings",
                buttonAction: { PasteboardPrivacy.openSystemSettings() }
            ))
        }
        result.append(OnboardingPage(
            icon: "arrow.down.doc",
            title: "Auto-paste (optional)",
            body: "With Accessibility permission, selecting an item pastes it directly into the app you were using. Without it, items are still copied to the clipboard for manual ⌘V. You can enable this any time.",
            buttonTitle: "Enable Auto-Paste",
            buttonAction: { AccessibilityPermission.requestPostEventAccess() }
        ))
        return result
    }

    var body: some View {
        let pages = self.pages
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: pages[pageIndex].icon)
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(pages[pageIndex].title)
                .font(.title2.weight(.semibold))
            Text(pages[pageIndex].body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            if let buttonTitle = pages[pageIndex].buttonTitle {
                Button(buttonTitle) {
                    pages[pageIndex].buttonAction?()
                }
            }
            Spacer()
            HStack {
                Button("Skip") { onFinish() }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { index in
                        Circle()
                            .fill(index == pageIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if pageIndex < pages.count - 1 {
                    Button("Continue") { pageIndex += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { onFinish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480, height: 360)
    }
}

private struct OnboardingPage {
    let icon: String
    let title: String
    let body: String
    var buttonTitle: String?
    var buttonAction: (() -> Void)?
}
