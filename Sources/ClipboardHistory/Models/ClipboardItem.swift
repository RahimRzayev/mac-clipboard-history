import CryptoKit
import Foundation

/// A single clipboard history entry. `content` is held decrypted in memory only;
/// at rest it is AES-GCM encrypted (see SQLiteClipboardStorage).
struct ClipboardItem: Identifiable, Equatable {
    static let textContentType = "public.utf8-plain-text"

    let id: UUID
    let content: String
    /// Derived for row rendering; never persisted in plaintext.
    let preview: String
    /// UTI. Always `public.utf8-plain-text` in v1; exists now so v2 binary types are additive.
    let contentType: String
    /// When this content was first copied.
    let createdAt: Date
    /// When this content was most recently copied (dedup bumps this; it is the list sort key).
    var lastCapturedAt: Date
    /// When the user last pasted this item from history. Never affects ordering.
    var lastUsedAt: Date?
    var useCount: Int
    var isPinned: Bool
    let sizeBytes: Int
    let sourceBundleID: String?
    let sourceAppName: String?
    /// SHA-256 of the whitespace-trimmed content, computed once at creation. A digest
    /// (not the trimmed string) so the per-capture dedup scan over the whole history
    /// stays O(items) in memory instead of re-copying every item's full content.
    let dedupKey: String

    init(
        id: UUID = UUID(),
        content: String,
        contentType: String = ClipboardItem.textContentType,
        createdAt: Date = Date(),
        lastCapturedAt: Date? = nil,
        lastUsedAt: Date? = nil,
        useCount: Int = 0,
        isPinned: Bool = false,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil
    ) {
        self.id = id
        self.content = content
        self.preview = ClipboardItem.makePreview(from: content)
        self.contentType = contentType
        self.createdAt = createdAt
        self.lastCapturedAt = lastCapturedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.isPinned = isPinned
        self.sizeBytes = content.utf8.count
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.dedupKey = ClipboardItem.makeDedupKey(content)
    }

    /// Digest of the normalized form, used ONLY for duplicate comparison; the original
    /// verbatim content is what gets saved.
    static func makeDedupKey(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(trimmed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var lineCount: Int {
        var count = 1
        for character in content where character == "\n" { count += 1 }
        return count
    }

    var isMultiline: Bool { lineCount > 1 }

    /// First two non-empty lines, leading whitespace collapsed, capped at 200 characters —
    /// keeps rows scannable and equal-height for predictable arrow-key navigation.
    static func makePreview(from content: String) -> String {
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(2)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let joined = lines.joined(separator: "\n")
        return String(joined.prefix(200))
    }
}
