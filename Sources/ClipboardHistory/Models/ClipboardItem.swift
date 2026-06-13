import CoreGraphics
import CryptoKit
import Foundation

/// The kind of content an item holds. Raw-string so it persists trivially.
enum ClipboardKind: String, Equatable {
    case text
    case image
    case file
}

/// One file inside a file-kind item. Names are sensitive (a filename can leak as much as
/// content), so they are encrypted at rest via the manifest blob (see SQLiteClipboardStorage).
struct FileEntry: Equatable, Codable {
    let name: String
    let uti: String
    let byteCount: Int64
}

/// A single clipboard history entry. All sensitive fields (content, thumbnail, file names)
/// are held DECRYPTED in memory and encrypted only at the storage boundary — this is what
/// lets Clear History's key-rotation re-encrypt everything by simply re-inserting items.
struct ClipboardItem: Identifiable, Equatable {
    static let textContentType = "public.utf8-plain-text"
    static let imageSentinel = "image"

    let id: UUID
    let kind: ClipboardKind
    /// Text: the verbatim string. Image: the sentinel "image". File: newline-joined file
    /// names (kept so the v1 in-memory search over decrypted content still finds files).
    let content: String
    /// Derived for row rendering; never persisted in plaintext.
    let preview: String
    /// UTI. `public.utf8-plain-text` for text; e.g. `public.png` for images; the first
    /// file's UTI for file items.
    let contentType: String
    let createdAt: Date
    /// When this content was most recently copied (dedup bumps this; it is the list sort key).
    var lastCapturedAt: Date
    /// When the user last pasted this item from history. Never affects ordering.
    var lastUsedAt: Date?
    var useCount: Int
    var isPinned: Bool
    /// Text: utf8 byte count. Image/file: on-disk payload byte count.
    let sizeBytes: Int64
    let sourceBundleID: String?
    let sourceAppName: String?
    /// Duplicate-comparison digest. Text: SHA-256 of trimmed content. Image: SHA-256 of raw
    /// bytes. File: SHA-256 of the sorted name+size+content digests.
    let dedupKey: String

    // MARK: Binary-kind fields (nil for text)

    /// PLAINTEXT JPEG thumbnail, in memory only — encrypted into thumb_enc at the storage
    /// boundary. Image items only.
    let thumbnail: Data?
    /// Pixel dimensions for the image preview label. Image items only.
    let imagePixelSize: CGSize?
    /// File manifest. File items only; names are encrypted at rest via manifest_enc.
    let fileEntries: [FileEntry]?

    // MARK: - Text init (v1-compatible: existing call sites compile unchanged)

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
        self.kind = .text
        self.content = content
        self.preview = ClipboardItem.makePreview(from: content)
        self.contentType = contentType
        self.createdAt = createdAt
        self.lastCapturedAt = lastCapturedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.isPinned = isPinned
        self.sizeBytes = Int64(content.utf8.count)
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.dedupKey = ClipboardItem.makeDedupKey(content)
        self.thumbnail = nil
        self.imagePixelSize = nil
        self.fileEntries = nil
    }

    // MARK: - Binary init (image / file)

    init(
        id: UUID = UUID(),
        kind: ClipboardKind,
        contentType: String,
        sizeBytes: Int64,
        dedupKey: String,
        createdAt: Date = Date(),
        lastCapturedAt: Date? = nil,
        lastUsedAt: Date? = nil,
        useCount: Int = 0,
        isPinned: Bool = false,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        thumbnail: Data? = nil,
        imagePixelSize: CGSize? = nil,
        fileEntries: [FileEntry]? = nil
    ) {
        precondition(kind != .text, "Use the text initializer for text items")
        self.id = id
        self.kind = kind
        switch kind {
        case .image:
            self.content = ClipboardItem.imageSentinel
        case .file:
            self.content = (fileEntries ?? []).map(\.name).joined(separator: "\n")
        case .text:
            self.content = ""
        }
        self.contentType = contentType
        self.createdAt = createdAt
        self.lastCapturedAt = lastCapturedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.isPinned = isPinned
        self.sizeBytes = sizeBytes
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.dedupKey = dedupKey
        self.thumbnail = thumbnail
        self.imagePixelSize = imagePixelSize
        self.fileEntries = fileEntries
        self.preview = ClipboardItem.makeBinaryPreview(
            kind: kind, imagePixelSize: imagePixelSize, fileEntries: fileEntries
        )
    }

    // MARK: - Derived

    /// Digest of the normalized form, used ONLY for text duplicate comparison; the original
    /// verbatim content is what gets saved.
    static func makeDedupKey(_ content: String) -> String {
        digestHex(Data(content.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    static func digestHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Kind-prefixed so an image/file digest can never collide with a text digest in the
    /// single cross-kind dedup scan.
    static func imageDedupKey(_ data: Data) -> String {
        "img:" + digestHex(data)
    }

    /// Order-independent digest over each file's name, size, and content hash.
    static func fileDedupKey(_ files: [(name: String, data: Data)]) -> String {
        let parts = files
            .map { "\($0.name)|\($0.data.count)|\(digestHex($0.data))" }
            .sorted()
        return "file:" + digestHex(Data(parts.joined(separator: "\n").utf8))
    }

    /// Text searched by content; image by type/dimensions; file by names. Source app name
    /// is matched separately by the store.
    var searchableText: String {
        switch kind {
        case .text:
            return content
        case .image:
            let dims = imagePixelSize.map { " \(Int($0.width))x\(Int($0.height))" } ?? ""
            return "image \(contentType)\(dims)"
        case .file:
            return (fileEntries ?? []).map(\.name).joined(separator: " ")
        }
    }

    /// Text-only line metrics; binary kinds report a single line.
    var lineCount: Int {
        guard kind == .text else { return 1 }
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

    static func makeBinaryPreview(
        kind: ClipboardKind, imagePixelSize: CGSize?, fileEntries: [FileEntry]?
    ) -> String {
        switch kind {
        case .image:
            if let size = imagePixelSize, size.width > 0, size.height > 0 {
                return "Image · \(Int(size.width))×\(Int(size.height))"
            }
            return "Image"
        case .file:
            let entries = fileEntries ?? []
            guard let first = entries.first else { return "File" }
            return entries.count > 1 ? "\(first.name)  +\(entries.count - 1) more" : first.name
        case .text:
            return ""
        }
    }
}
