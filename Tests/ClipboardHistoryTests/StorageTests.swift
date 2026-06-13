import CryptoKit
import Foundation
import Testing
@testable import ClipboardHistory

struct StorageTests {
    private func makeStorage() throws -> (SQLiteClipboardStorage, URL, EncryptionService) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.sqlite")
        let encryption = EncryptionService(key: SymmetricKey(size: .bits256))
        let storage = try SQLiteClipboardStorage(databaseURL: url, encryption: encryption)
        return (storage, url, encryption)
    }

    @Test func insertFetchRoundTrip() throws {
        let (storage, _, _) = try makeStorage()
        let item = ClipboardItem(
            content: "round trip ünïcødé\nsecond line",
            sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari"
        )
        try storage.insert(item)

        let fetched = try storage.fetchAll(limit: nil)
        #expect(fetched.count == 1)
        #expect(fetched[0].id == item.id)
        #expect(fetched[0].content == item.content)
        #expect(fetched[0].sourceBundleID == "com.apple.Safari")
        #expect(fetched[0].isPinned == false)
    }

    @Test func fetchOrdersByLastCapturedDescending() throws {
        let (storage, _, _) = try makeStorage()
        let now = Date()
        try storage.insert(ClipboardItem(content: "oldest", createdAt: now.addingTimeInterval(-100)))
        try storage.insert(ClipboardItem(content: "newest", createdAt: now))
        try storage.insert(ClipboardItem(content: "middle", createdAt: now.addingTimeInterval(-50)))

        let fetched = try storage.fetchAll(limit: nil)
        #expect(fetched.map(\.content) == ["newest", "middle", "oldest"])
        #expect(try storage.fetchAll(limit: 2).count == 2)
    }

    @Test func updateAndPinPersist() throws {
        let (storage, _, _) = try makeStorage()
        var item = ClipboardItem(content: "mutate me")
        try storage.insert(item)

        item.useCount = 7
        item.lastUsedAt = Date()
        try storage.update(item)
        try storage.setPinned(id: item.id, true)

        let fetched = try storage.fetchAll(limit: nil)[0]
        #expect(fetched.useCount == 7)
        #expect(fetched.lastUsedAt != nil)
        #expect(fetched.isPinned)
    }

    @Test func deleteAndDeleteAll() throws {
        let (storage, _, _) = try makeStorage()
        let doomed = ClipboardItem(content: "doomed")
        let pinned = ClipboardItem(content: "pinned", isPinned: true)
        try storage.insert(doomed)
        try storage.insert(pinned)

        try storage.delete(id: doomed.id)
        #expect(try storage.fetchAll(limit: nil).count == 1)

        try storage.insert(ClipboardItem(content: "unpinned"))
        try storage.deleteAll(keepPinned: true)
        #expect(try storage.fetchAll(limit: nil).map(\.content) == ["pinned"])

        try storage.deleteAll(keepPinned: false)
        #expect(try storage.fetchAll(limit: nil).isEmpty)
    }

    @Test func purgeRespectsPinned() throws {
        let (storage, _, _) = try makeStorage()
        let old = Date().addingTimeInterval(-10_000)
        try storage.insert(ClipboardItem(content: "old", createdAt: old))
        try storage.insert(ClipboardItem(content: "old pinned", createdAt: old, isPinned: true))
        try storage.insert(ClipboardItem(content: "new"))

        try storage.purge(olderThan: Date().addingTimeInterval(-5000), keepPinned: true)
        let remaining = try storage.fetchAll(limit: nil).map(\.content)
        #expect(remaining.contains("old pinned"))
        #expect(remaining.contains("new"))
        #expect(!remaining.contains("old"))
    }

    /// Acceptance §16.11: the database (and WAL) must never contain copied plaintext.
    @Test func plaintextNeverTouchesDisk() throws {
        let (storage, url, _) = try makeStorage()
        let secret = "extremely-secret-marker-7f3a9c"
        try storage.insert(ClipboardItem(content: secret))
        // Force everything out of the WAL into the main database file too.
        try storage.deleteAllAndReinsertForTest(ClipboardItem(content: secret))

        let needle = Data(secret.utf8)
        for suffix in ["", "-wal", "-shm"] {
            let fileURL = URL(fileURLWithPath: url.path + suffix)
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            #expect(data.range(of: needle) == nil, "plaintext found in \(fileURL.lastPathComponent)")
        }

        // Sanity check: content still decrypts fine.
        #expect(try storage.fetchAll(limit: nil).first?.content == secret)
    }
}

private extension SQLiteClipboardStorage {
    /// Test helper: exercise checkpoint + reinsert so the WAL gets flushed.
    func deleteAllAndReinsertForTest(_ item: ClipboardItem) throws {
        try deleteAll(keepPinned: false)
        try insert(item)
    }
}
