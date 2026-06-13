import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import ClipboardHistory

private let SQLITE_TRANSIENT_T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct BinaryStorageTests {
    private func makeStorage() throws -> (SQLiteClipboardStorage, URL, EncryptionService) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BinStorageTests-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("history.sqlite")
        let encryption = EncryptionService(key: SymmetricKey(size: .bits256))
        return (try SQLiteClipboardStorage(databaseURL: url, encryption: encryption), url, encryption)
    }

    @Test func imageItemRoundTrip() throws {
        let (storage, _, _) = try makeStorage()
        let thumb = Data((0..<512).map { UInt8($0 % 256) })
        let item = ClipboardItem(
            kind: .image, contentType: "public.png", sizeBytes: 4_000_000,
            dedupKey: "img:abc123", sourceAppName: "Safari", thumbnail: thumb,
            imagePixelSize: CGSize(width: 1920, height: 1080)
        )
        try storage.insert(item)

        let fetched = try #require(try storage.fetchAll(limit: nil).first)
        #expect(fetched.kind == .image)
        #expect(fetched.contentType == "public.png")
        #expect(fetched.sizeBytes == 4_000_000)
        #expect(fetched.dedupKey == "img:abc123")
        #expect(fetched.thumbnail == thumb)
        #expect(fetched.imagePixelSize == CGSize(width: 1920, height: 1080))
    }

    @Test func fileItemRoundTrip() throws {
        let (storage, _, _) = try makeStorage()
        let entries = [
            FileEntry(name: "report.pdf", uti: "com.adobe.pdf", byteCount: 1234),
            FileEntry(name: "photo.heic", uti: "public.heic", byteCount: 5678),
        ]
        let item = ClipboardItem(
            kind: .file, contentType: "com.adobe.pdf", sizeBytes: 6912,
            dedupKey: "file:def456", fileEntries: entries
        )
        try storage.insert(item)

        let fetched = try #require(try storage.fetchAll(limit: nil).first)
        #expect(fetched.kind == .file)
        #expect(fetched.fileEntries == entries)
        #expect(fetched.preview.contains("report.pdf"))
    }

    @Test func binaryRowSkippedWhenUndecryptable() throws {
        let (storage, _, encryption) = try makeStorage()
        try storage.insert(ClipboardItem(content: "survivor"))
        try storage.insert(ClipboardItem(
            kind: .image, contentType: "public.png", sizeBytes: 10, dedupKey: "img:x",
            thumbnail: Data([1, 2, 3])
        ))
        // Rotate the key underneath: every row's content_enc now fails to decrypt → all skipped.
        encryption.replaceKey(SymmetricKey(size: .bits256))
        #expect(try storage.fetchAll(limit: nil).isEmpty)
    }

    @Test func plaintextNeverTouchesDiskForFileNames() throws {
        let (storage, url, _) = try makeStorage()
        let secretName = "severance-agreement-SECRET.pdf"
        try storage.insert(ClipboardItem(
            kind: .file, contentType: "com.adobe.pdf", sizeBytes: 10, dedupKey: "file:y",
            fileEntries: [FileEntry(name: secretName, uti: "com.adobe.pdf", byteCount: 10)]
        ))
        // Flush WAL into the main file.
        try storage.deleteAll(keepPinned: true)
        try storage.insert(ClipboardItem(
            kind: .file, contentType: "com.adobe.pdf", sizeBytes: 10, dedupKey: "file:z",
            fileEntries: [FileEntry(name: secretName, uti: "com.adobe.pdf", byteCount: 10)]
        ))
        let needle = Data(secretName.utf8)
        for suffix in ["", "-wal", "-shm"] {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: url.path + suffix)) {
                #expect(data.range(of: needle) == nil, "filename leaked in \(suffix.isEmpty ? "db" : suffix)")
            }
        }
    }

    // MARK: - Migration v1 -> v2

    @Test func migratesV1DatabaseToV2PreservingTextRow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("history.sqlite")
        let key = SymmetricKey(size: .bits256)
        let encryption = EncryptionService(key: key)

        try buildV1Database(at: url, content: "legacy text", encryption: encryption)

        // Open with the current code → should migrate to v2.
        let storage = try SQLiteClipboardStorage(databaseURL: url, encryption: EncryptionService(key: key))
        #expect(try readUserVersion(url) == 2)

        let items = try storage.fetchAll(limit: nil)
        #expect(items.count == 1)
        let legacy = try #require(items.first)
        #expect(legacy.kind == .text)
        #expect(legacy.content == "legacy text")
        #expect(legacy.thumbnail == nil)
        #expect(legacy.fileEntries == nil)

        // And the migrated DB accepts a new binary item.
        try storage.insert(ClipboardItem(
            kind: .image, contentType: "public.png", sizeBytes: 99, dedupKey: "img:new",
            thumbnail: Data([9, 9, 9])
        ))
        #expect(try storage.fetchAll(limit: nil).contains { $0.kind == .image })
    }

    private func buildV1Database(at url: URL, content: String, encryption: EncryptionService) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        exec(db, "PRAGMA journal_mode = WAL")
        exec(db, """
            CREATE TABLE items (
              id TEXT PRIMARY KEY, created_at REAL NOT NULL, last_captured_at REAL NOT NULL,
              last_used_at REAL, use_count INTEGER NOT NULL DEFAULT 0, is_pinned INTEGER NOT NULL DEFAULT 0,
              content_type TEXT NOT NULL, size_bytes INTEGER NOT NULL, source_bundle_id TEXT,
              source_app_name TEXT, content_enc BLOB NOT NULL)
            """)
        exec(db, "CREATE INDEX idx_items_captured ON items(last_captured_at DESC)")

        let blob = try encryption.encrypt(content)
        var stmt: OpaquePointer?
        let sql = "INSERT INTO items (id, created_at, last_captured_at, last_used_at, use_count, is_pinned, content_type, size_bytes, source_bundle_id, source_app_name, content_enc) VALUES (?,?,?,?,?,?,?,?,?,?,?)"
        #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, SQLITE_TRANSIENT_T)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        sqlite3_bind_null(stmt, 4)
        sqlite3_bind_int64(stmt, 5, 0)
        sqlite3_bind_int(stmt, 6, 0)
        sqlite3_bind_text(stmt, 7, ClipboardItem.textContentType, -1, SQLITE_TRANSIENT_T)
        sqlite3_bind_int64(stmt, 8, Int64(content.utf8.count))
        sqlite3_bind_null(stmt, 9)
        sqlite3_bind_null(stmt, 10)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 11, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT_T) }
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
        exec(db, "PRAGMA user_version = 1")
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func readUserVersion(_ url: URL) throws -> Int {
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}
