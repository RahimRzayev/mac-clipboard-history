import Foundation

/// Heuristic for "this looks like a generated password" (spec §6.4 gap mitigation).
///
/// Why this exists: password-manager BROWSER EXTENSIONS (Norton, 1Password, Bitwarden —
/// verified June 2026) do not set org.nspasteboard.ConcealedType, and their copies are
/// attributed to the browser process, so neither the marker check nor the excluded-apps
/// list can catch them. This is the last net, and it is deliberately conservative:
/// missing some passwords is acceptable, silently eating text the user wanted is not.
enum SensitiveTextDetector {
    /// True if the text matches the shape of a password: one token, 8–64 chars,
    /// mixed character classes, and not an obviously-benign format (URL, email,
    /// file path, hex hash/UUID).
    static func looksLikePassword(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.count <= 64 else { return false }
        guard !trimmed.contains(where: \.isWhitespace) else { return false }

        // Benign single-token formats users copy constantly:
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("www.") || trimmed.contains("://") {
            return false // URLs
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".") {
            return false // file paths / dotfiles
        }
        if trimmed.contains("@") {
            return false // emails, handles
        }
        let hexAndSeparators = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        if trimmed.unicodeScalars.allSatisfy({ hexAndSeparators.contains($0) }) {
            return false // git SHAs, UUIDs, hex blobs
        }

        // Character-class analysis.
        enum CharClass { case lower, upper, digit, symbol }
        var classes: Set<CharClass> = []
        var transitions = 0
        var digitRuns = 0
        var previous: CharClass?
        for character in trimmed {
            let current: CharClass
            if character.isLowercase { current = .lower }
            else if character.isUppercase { current = .upper }
            else if character.isNumber { current = .digit }
            else { current = .symbol }
            classes.insert(current)
            if previous != current {
                transitions += previous == nil ? 0 : 1
                if current == .digit { digitRuns += 1 }
            }
            previous = current
        }

        // All four classes (lower+upper+digit+symbol) in one 8+ char token: virtually
        // always a generated password ("kX9#mP2$vL").
        if classes.count == 4 {
            return true
        }
        // Three classes only counts when long AND choppy AND digits are interleaved:
        // generated passwords alternate classes constantly with digits scattered through
        // ("aB3xKp9Qw2Lm"), while human tokens group their classes and keep digits in a
        // single trailing run ("ClipboardItem2", "getUserById42").
        if classes.count == 3, trimmed.count >= 12, transitions >= 5, digitRuns >= 2 {
            return true
        }
        return false
    }
}
