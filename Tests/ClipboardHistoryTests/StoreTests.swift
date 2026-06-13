import CryptoKit
import Foundation
import Testing
@testable import ClipboardHistory

@MainActor
struct StoreTests {
    private func makeStore(
        maxItems: Int = 500,
        retentionDays: Int = 30,
        rotate: @escaping () throws -> Void = {}
    ) -> (ClipboardStore, MemoryClipboardStorage) {
        let storage = MemoryClipboardStorage()
        let store = ClipboardStore(
            storage: storage,
            maxItems: { maxItems },
            retentionDays: { retentionDays },
            rotateEncryptionKey: rotate
        )
        return (store, storage)
    }

    @Test func captureInsertsNewestFirst() throws {
        let (store, storage) = makeStore()
        store.capture(content: "first", sourceBundleID: nil, sourceAppName: nil)
        store.capture(content: "second", sourceBundleID: "com.apple.Safari", sourceAppName: "Safari")
        #expect(store.items.count == 2)
        #expect(store.items[0].content == "second")
        #expect(store.items[0].sourceAppName == "Safari")
        #expect(try storage.fetchAll(limit: nil).count == 2)
    }

    @Test func duplicateMovesToTopWithoutNewRow() throws {
        let (store, storage) = makeStore()
        store.capture(content: "alpha", sourceBundleID: nil, sourceAppName: nil)
        store.capture(content: "beta", sourceBundleID: nil, sourceAppName: nil)
        store.capture(content: "alpha", sourceBundleID: nil, sourceAppName: nil)

        #expect(store.items.count == 2)
        #expect(store.items[0].content == "alpha")
        #expect(store.items[0].useCount == 1)
        #expect(try storage.fetchAll(limit: nil).count == 2)
    }

    @Test func dedupComparesTrimmedButKeepsOriginal() {
        let (store, _) = makeStore()
        store.capture(content: "  hello \n", sourceBundleID: nil, sourceAppName: nil)
        store.capture(content: "hello", sourceBundleID: nil, sourceAppName: nil)
        #expect(store.items.count == 1)
        // The original verbatim value stays saved (spec §5.7).
        #expect(store.items[0].content == "  hello \n")
    }

    @Test func recordUseDoesNotReorder() {
        let (store, _) = makeStore()
        store.capture(content: "older", sourceBundleID: nil, sourceAppName: nil)
        store.capture(content: "newer", sourceBundleID: nil, sourceAppName: nil)
        let older = store.items[1]
        store.recordUse(of: older.id)

        // Acceptance §16.8: pasting from history must not reorder.
        #expect(store.items[0].content == "newer")
        #expect(store.items[1].useCount == 1)
        #expect(store.items[1].lastUsedAt != nil)
    }

    @Test func maxItemsTrimsOldestUnpinnedOnly() {
        let (store, _) = makeStore(maxItems: 3)
        store.capture(content: "one", sourceBundleID: nil, sourceAppName: nil)
        guard let pinnedID = store.items.first?.id else {
            Issue.record("missing item")
            return
        }
        store.setPinned(id: pinnedID, true)
        for content in ["two", "three", "four", "five"] {
            store.capture(content: content, sourceBundleID: nil, sourceAppName: nil)
        }

        #expect(store.recentItems.count == 3)
        #expect(store.recentItems.map(\.content) == ["five", "four", "three"])
        // Pinned item survives trimming (spec §7).
        #expect(store.pinnedItems.map(\.content) == ["one"])
    }

    @Test func retentionPurgeKeepsPinned() throws {
        let storage = MemoryClipboardStorage()
        let old = Date().addingTimeInterval(-40 * 86_400)
        try storage.insert(ClipboardItem(content: "old unpinned", createdAt: old))
        try storage.insert(ClipboardItem(content: "old pinned", createdAt: old, isPinned: true))
        try storage.insert(ClipboardItem(content: "fresh"))

        let store = ClipboardStore(storage: storage, retentionDays: { 30 })
        store.applyRetention()

        #expect(store.items.count == 2)
        #expect(!store.items.contains { $0.content == "old unpinned" })
        #expect(store.items.contains { $0.content == "old pinned" })
    }

    @Test func retentionNeverWhenZero() throws {
        let storage = MemoryClipboardStorage()
        let ancient = Date().addingTimeInterval(-1000 * 86_400)
        try storage.insert(ClipboardItem(content: "ancient", createdAt: ancient))
        let store = ClipboardStore(storage: storage, retentionDays: { 0 })
        store.applyRetention()
        #expect(store.items.count == 1)
    }

    @Test func clearAllKeepsPinnedAndRotatesKey() throws {
        var rotated = false
        let (store, storage) = makeStore(rotate: { rotated = true })
        store.capture(content: "keep me", sourceBundleID: nil, sourceAppName: nil)
        store.setPinned(id: store.items[0].id, true)
        store.capture(content: "wipe me", sourceBundleID: nil, sourceAppName: nil)

        store.clearAll(includePinned: false)

        #expect(rotated)
        #expect(store.items.map(\.content) == ["keep me"])
        // Pinned survivor was re-inserted (re-encrypted under the new key, spec §7).
        #expect(try storage.fetchAll(limit: nil).map(\.content) == ["keep me"])
    }

    @Test func clearAllIncludingPinned() throws {
        var rotated = false
        let (store, storage) = makeStore(rotate: { rotated = true })
        store.capture(content: "pinned", sourceBundleID: nil, sourceAppName: nil)
        store.setPinned(id: store.items[0].id, true)

        store.clearAll(includePinned: true)

        #expect(rotated)
        #expect(store.items.isEmpty)
        #expect(try storage.fetchAll(limit: nil).isEmpty)
    }

    @Test func clearAllSurvivesRotationFailure() throws {
        // The data-loss bug the review caught: rotation throwing after pinned rows were
        // already deleted. With the fixed ordering, a failed rotation must leave pinned
        // items intact on disk AND in memory.
        struct RotationError: Error {}
        let (store, storage) = makeStore(rotate: { throw RotationError() })
        store.capture(content: "keep me", sourceBundleID: nil, sourceAppName: nil)
        store.setPinned(id: store.items[0].id, true)
        store.capture(content: "wipe me", sourceBundleID: nil, sourceAppName: nil)

        store.clearAll(includePinned: false)

        #expect(store.items.map(\.content) == ["keep me"])
        #expect(try storage.fetchAll(limit: nil).map(\.content) == ["keep me"])
    }

    @Test func searchIsCaseInsensitive() {
        let (store, _) = makeStore()
        store.capture(content: "Hello World", sourceBundleID: nil, sourceAppName: nil)
        store.capture(content: "other", sourceBundleID: nil, sourceAppName: nil)
        #expect(store.search("hello w").map(\.content) == ["Hello World"])
        #expect(store.search("  ").count == 2) // blank query returns everything
    }
}
