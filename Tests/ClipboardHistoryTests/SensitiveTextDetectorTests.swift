import Testing
@testable import ClipboardHistory

struct SensitiveTextDetectorTests {
    // MARK: - Should be detected (password-shaped)

    @Test func generatedFourClassPasswords() {
        #expect(SensitiveTextDetector.looksLikePassword("kX9#mP2$vL"))
        #expect(SensitiveTextDetector.looksLikePassword("Tr0ub4dor&3x"))
        #expect(SensitiveTextDetector.looksLikePassword("aB3!xKp9Qw2L"))
        #expect(SensitiveTextDetector.looksLikePassword("Summer2024!Ab")) // 13 chars, 4 classes
    }

    @Test func generatedThreeClassChoppyPasswords() {
        // 12+ chars, three classes, classes alternate constantly — generated shape.
        #expect(SensitiveTextDetector.looksLikePassword("aB3xKp9Qw2Lm"))
        #expect(SensitiveTextDetector.looksLikePassword("x7Rq2mN8pT4z"))
    }

    @Test func leadingTrailingWhitespaceIsIgnored() {
        #expect(SensitiveTextDetector.looksLikePassword("  kX9#mP2$vL\n"))
    }

    // MARK: - Should NOT be detected (benign single tokens)

    @Test func ordinaryTextPasses() {
        #expect(!SensitiveTextDetector.looksLikePassword("hello world"))
        #expect(!SensitiveTextDetector.looksLikePassword("multi\nline\ntext"))
        #expect(!SensitiveTextDetector.looksLikePassword("lowercaseword"))
        #expect(!SensitiveTextDetector.looksLikePassword("Ab1!")) // too short
    }

    @Test func urlsPass() {
        #expect(!SensitiveTextDetector.looksLikePassword("https://example.com/Path?q=1&x=2"))
        #expect(!SensitiveTextDetector.looksLikePassword("www.Example123.com"))
        #expect(!SensitiveTextDetector.looksLikePassword("ssh://Host123:22/Path"))
    }

    @Test func emailsAndHandlesPass() {
        #expect(!SensitiveTextDetector.looksLikePassword("John.Doe123@mail.com"))
        #expect(!SensitiveTextDetector.looksLikePassword("@SomeHandle42"))
    }

    @Test func pathsPass() {
        #expect(!SensitiveTextDetector.looksLikePassword("/usr/local/Bin123"))
        #expect(!SensitiveTextDetector.looksLikePassword("~/Library/Caches2"))
        #expect(!SensitiveTextDetector.looksLikePassword(".env.Production1"))
    }

    @Test func hashesAndUUIDsPass() {
        #expect(!SensitiveTextDetector.looksLikePassword("9f86d081884c7d659a2feaa0c55ad015a3bf4f1b"))
        #expect(!SensitiveTextDetector.looksLikePassword("B7E1F2A0-3C4D-4E5F-9A8B-1C2D3E4F5A6B"))
    }

    @Test func humanIdentifiersPass() {
        // Mixed-case identifiers with a digit group their classes (few transitions).
        #expect(!SensitiveTextDetector.looksLikePassword("ClipboardItem2"))
        #expect(!SensitiveTextDetector.looksLikePassword("iPhone15Pro"))
        #expect(!SensitiveTextDetector.looksLikePassword("NSPasteboardType"))
        #expect(!SensitiveTextDetector.looksLikePassword("getUserById42"))
    }
}

@MainActor
struct SensitiveAppNameTests {
    @Test func passwordManagerNamesMatch() {
        #expect(ClipboardWatcher.isSensitiveAppName("Norton Password Manager"))
        #expect(ClipboardWatcher.isSensitiveAppName("Passwords"))
        #expect(ClipboardWatcher.isSensitiveAppName("KeePassXC"))
        #expect(ClipboardWatcher.isSensitiveAppName("Keychain Access"))
        #expect(ClipboardWatcher.isSensitiveAppName("Passwort-Manager"))
    }

    @Test func ordinaryAppNamesDoNotMatch() {
        #expect(!ClipboardWatcher.isSensitiveAppName("Google Chrome"))
        #expect(!ClipboardWatcher.isSensitiveAppName("Code"))
        #expect(!ClipboardWatcher.isSensitiveAppName("Safari"))
        #expect(!ClipboardWatcher.isSensitiveAppName(nil))
    }
}
