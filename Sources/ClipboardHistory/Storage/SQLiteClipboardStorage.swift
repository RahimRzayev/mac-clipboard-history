import Foundation
import SQLite3

// swiftlint:disable:next identifier_name
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum StorageError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed
}

/// SQLite persistence via the system sqlite3 C library (zero external dependencies).
/// Content is encrypted before it ever reaches SQLite, so neither the database file nor
/// its WAL/journal can contain copied plaintext (acceptance criterion §16.11).
final class SQLiteClipboardStorage: ClipboardStorage {
    private var db: OpaquePointer?
    private let encryption: EncryptionService

    init(databaseURL: URL, encryption: EncryptionService) throws {
        self.encryption = encryption

        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw StorageError.openFailed(message)
        }
        db = handle

        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA foreign_keys = ON")
        try migrateIfNeeded()

        // Content is encrypted, but metadata (timestamps, source apps) still leaks usage
        // patterns — restrict the files regardless of what the parent directories allow.
        // createDirectory only applies permissions when it CREATES the directory, and
        // sqlite creates db/-wal/-shm with the default umask, so set both explicitly.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    private func migrateIfNeeded() throws {
        let version = try scalarInt("PRAGMA user_version")
        if version < 1 {
            try exec("""
                CREATE TABLE IF NOT EXISTS items (
                  id               TEXT PRIMARY KEY,
                  created_at       REAL NOT NULL,
                  last_captured_at REAL NOT NULL,
                  last_used_at     REAL,
                  use_count        INTEGER NOT NULL DEFAULT 0,
                  is_pinned        INTEGER NOT NULL DEFAULT 0,
                  content_type     TEXT NOT NULL,
                  size_bytes       INTEGER NOT NULL,
                  source_bundle_id TEXT,
                  source_app_name  TEXT,
                  content_enc      BLOB NOT NULL
                )
                """)
            try exec("CREATE INDEX IF NOT EXISTS idx_items_captured ON items(last_captured_at DESC)")
            try exec("PRAGMA user_version = 1")
        }
    }

    // MARK: - ClipboardStorage

    func insert(_ item: ClipboardItem) throws {
        let sql = """
            INSERT INTO items (id, created_at, last_captured_at, last_used_at, use_count, is_pinned,
                               content_type, size_bytes, source_bundle_id, source_app_name, content_enc)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        let encrypted = try encryption.encrypt(item.content)
        try bindText(statement, 1, item.id.uuidString)
        try check(sqlite3_bind_double(statement, 2, item.createdAt.timeIntervalSince1970))
        try check(sqlite3_bind_double(statement, 3, item.lastCapturedAt.timeIntervalSince1970))
        try bindOptionalDate(statement, 4, item.lastUsedAt)
        try check(sqlite3_bind_int64(statement, 5, Int64(item.useCount)))
        try check(sqlite3_bind_int(statement, 6, item.isPinned ? 1 : 0))
        try bindText(statement, 7, item.contentType)
        try check(sqlite3_bind_int64(statement, 8, Int64(item.sizeBytes)))
        try bindOptionalText(statement, 9, item.sourceBundleID)
        try bindOptionalText(statement, 10, item.sourceAppName)
        let blobStatus = encrypted.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, 11, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
        }
        try check(blobStatus)
        try step(statement)
    }

    func update(_ item: ClipboardItem) throws {
        let sql = """
            UPDATE items
            SET last_captured_at = ?, last_used_at = ?, use_count = ?, is_pinned = ?
            WHERE id = ?
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try check(sqlite3_bind_double(statement, 1, item.lastCapturedAt.timeIntervalSince1970))
        try bindOptionalDate(statement, 2, item.lastUsedAt)
        try check(sqlite3_bind_int64(statement, 3, Int64(item.useCount)))
        try check(sqlite3_bind_int(statement, 4, item.isPinned ? 1 : 0))
        try bindText(statement, 5, item.id.uuidString)
        try step(statement)
    }

    func delete(id: UUID) throws {
        let statement = try prepare("DELETE FROM items WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, id.uuidString)
        try step(statement)
    }

    func deleteAll(keepPinned: Bool) throws {
        if keepPinned {
            try exec("DELETE FROM items WHERE is_pinned = 0")
        } else {
            try exec("DELETE FROM items")
        }
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func purge(olderThan cutoff: Date, keepPinned: Bool) throws {
        let sql = keepPinned
            ? "DELETE FROM items WHERE last_captured_at < ? AND is_pinned = 0"
            : "DELETE FROM items WHERE last_captured_at < ?"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970))
        try step(statement)
    }

    func fetchAll(limit: Int?) throws -> [ClipboardItem] {
        // Deterministic tie-breakers keep ordering stable across relaunches and match
        // MemoryClipboardStorage when lastCapturedAt collides (fixtures, imports).
        var sql = "SELECT id, created_at, last_captured_at, last_used_at, use_count, is_pinned, content_type, source_bundle_id, source_app_name, content_enc FROM items ORDER BY last_captured_at DESC, created_at DESC, id"
        if let limit {
            sql += " LIMIT \(limit)"
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var items: [ClipboardItem] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            defer { stepResult = sqlite3_step(statement) }
            guard
                let idText = columnText(statement, 0),
                let id = UUID(uuidString: idText),
                let blob = columnBlob(statement, 9),
                let content = try? encryption.decrypt(blob)
            else {
                // A row that fails to decrypt (e.g. key rotated underneath us) is skipped,
                // not fatal — the rest of history stays usable.
                continue
            }
            let item = ClipboardItem(
                id: id,
                content: content,
                contentType: columnText(statement, 6) ?? ClipboardItem.textContentType,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                lastCapturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                lastUsedAt: columnOptionalDate(statement, 3),
                useCount: Int(sqlite3_column_int64(statement, 4)),
                isPinned: sqlite3_column_int(statement, 5) != 0,
                sourceBundleID: columnText(statement, 7),
                sourceAppName: columnText(statement, 8)
            )
            items.append(item)
        }
        // An I/O error / corruption mid-scan must throw, not masquerade as end-of-results —
        // otherwise a truncated list is published as the app's complete state.
        guard stepResult == SQLITE_DONE else {
            throw StorageError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        return items
    }

    func setPinned(id: UUID, _ pinned: Bool) throws {
        let statement = try prepare("UPDATE items SET is_pinned = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int(statement, 1, pinned ? 1 : 0))
        try bindText(statement, 2, id.uuidString)
        try step(statement)
    }

    // MARK: - Helpers

    private func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw StorageError.stepFailed(message)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StorageError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StorageError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// A failed bind leaves the parameter NULL; for UPDATE/DELETE that means a WHERE
    /// matching zero rows and a silently dropped write — so every bind result is checked.
    private func check(_ resultCode: Int32) throws {
        guard resultCode == SQLITE_OK else { throw StorageError.bindFailed }
    }

    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) throws {
        try check(sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT))
    }

    private func bindOptionalText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) throws {
        if let value {
            try bindText(statement, index, value)
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    private func bindOptionalDate(_ statement: OpaquePointer, _ index: Int32, _ value: Date?) throws {
        if let value {
            try check(sqlite3_bind_double(statement, index, value.timeIntervalSince1970))
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func columnBlob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: count)
    }

    private func columnOptionalDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }
}
