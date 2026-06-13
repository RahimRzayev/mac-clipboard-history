import CryptoKit
import Foundation
import os.log

/// Owns all history business rules (dedup, caps, retention, pin exemptions) and is the single
/// owner of in-memory state. Storage is a write-through layer beneath it (spec §3).
@MainActor
final class ClipboardStore: ObservableObject {
    /// All items, newest-captured first. Search runs in memory over this array (spec §7).
    @Published private(set) var items: [ClipboardItem] = []

    private let storage: ClipboardStorage
    /// Owns the encrypted binary sidecar files. nil in memory-fallback mode, where image/file
    /// capture is skipped (text still works) since the bytes can't be persisted safely.
    private let payloadStore: PayloadStore?
    private let logger = Logger(subsystem: "ClipboardHistory", category: "store")

    /// Settings are injected as closures so the store is testable without UserDefaults.
    var maxItems: () -> Int
    /// 0 means "never".
    var retentionDays: () -> Int
    /// Called by Clear History to rotate the encryption key (spec §7). Returns nothing;
    /// kept pinned items are re-inserted (re-encrypted under the new key) by the store.
    var rotateEncryptionKey: () throws -> Void

    init(
        storage: ClipboardStorage,
        payloadStore: PayloadStore? = nil,
        maxItems: @escaping () -> Int = { 500 },
        retentionDays: @escaping () -> Int = { 30 },
        rotateEncryptionKey: @escaping () throws -> Void = {}
    ) {
        self.storage = storage
        self.payloadStore = payloadStore
        self.maxItems = maxItems
        self.retentionDays = retentionDays
        self.rotateEncryptionKey = rotateEncryptionKey
        reload()
        // Launch-time orphan GC: reclaim payload files with no surviving row.
        payloadStore?.sweep(keeping: binaryItemIDs())
    }

    private func binaryItemIDs() -> Set<UUID> {
        Set(items.filter { $0.kind != .text }.map(\.id))
    }

    /// Reads a binary item's payload bytes (decrypted). Used by paste-back.
    func payloadData(for id: UUID) throws -> Data {
        guard let payloadStore else { throw PayloadError.missing }
        return try payloadStore.read(id: id)
    }

    var pinnedItems: [ClipboardItem] { items.filter(\.isPinned) }
    var recentItems: [ClipboardItem] { items.filter { !$0.isPinned } }

    func reload() {
        do {
            items = try storage.fetchAll(limit: nil)
        } catch {
            logger.error("Failed to load history: \(error.localizedDescription)")
            items = []
        }
    }

    // MARK: - Capture

    /// Capture pipeline endpoint (spec §5.7–5.8): dedup against the whole history —
    /// an existing match moves to the top instead of inserting a new row.
    func capture(content: String, sourceBundleID: String?, sourceAppName: String?) {
        let key = ClipboardItem.makeDedupKey(content)
        if moveToTopIfDuplicate(key: key) { return }

        let item = ClipboardItem(
            content: content,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName
        )
        insertNew(item)
    }

    /// Image capture: dedup by content hash; write the encrypted payload BEFORE the row so a
    /// row never references a missing payload; thumbnail derived once for fast row rendering.
    func capture(image data: Data, uti: String, sourceBundleID: String?, sourceAppName: String?) {
        guard let payloadStore else { return } // can't persist bytes in memory-fallback mode
        let key = ClipboardItem.imageDedupKey(data)
        if moveToTopIfDuplicate(key: key) { return }

        let id = UUID()
        do {
            try payloadStore.write(id: id, plaintext: data)
        } catch {
            logger.error("Image payload write failed: \(error.localizedDescription)")
            return
        }
        let thumb = ThumbnailGenerator.make(from: data)
        let item = ClipboardItem(
            id: id, kind: .image, contentType: uti, sizeBytes: Int64(data.count), dedupKey: key,
            sourceBundleID: sourceBundleID, sourceAppName: sourceAppName,
            thumbnail: thumb?.jpeg, imagePixelSize: thumb?.pixelSize
        )
        insertNew(item, onPersistFailure: { payloadStore.delete(id: id) })
    }

    /// File capture: copy the bytes into the encrypted payload (self-contained paste-back).
    func capture(files: [(name: String, uti: String, data: Data)], sourceBundleID: String?, sourceAppName: String?) {
        guard let payloadStore, !files.isEmpty else { return }
        let key = ClipboardItem.fileDedupKey(files.map { ($0.name, $0.data) })
        if moveToTopIfDuplicate(key: key) { return }

        let id = UUID()
        do {
            let payload = try FilePayload.encode(files.map { ($0.name, $0.data) })
            try payloadStore.write(id: id, plaintext: payload)
        } catch {
            logger.error("File payload write failed: \(error.localizedDescription)")
            return
        }
        let entries = files.map { FileEntry(name: $0.name, uti: $0.uti, byteCount: Int64($0.data.count)) }
        let total = files.reduce(Int64(0)) { $0 + Int64($1.data.count) }
        let item = ClipboardItem(
            id: id, kind: .file, contentType: files[0].uti, sizeBytes: total, dedupKey: key,
            sourceBundleID: sourceBundleID, sourceAppName: sourceAppName, fileEntries: entries
        )
        insertNew(item, onPersistFailure: { payloadStore.delete(id: id) })
    }

    /// Shared dedup-hit handling: move the existing item to the top, bump use count. Returns
    /// true if a duplicate was found and handled (no new row/payload should be written).
    private func moveToTopIfDuplicate(key: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.dedupKey == key }) else { return false }
        var existing = items[index]
        existing.lastCapturedAt = Date()
        existing.useCount += 1
        items.remove(at: index)
        items.insert(existing, at: 0)
        persistUpdate(existing)
        return true
    }

    private func insertNew(_ item: ClipboardItem, onPersistFailure: () -> Void = {}) {
        items.insert(item, at: 0)
        do {
            try storage.insert(item)
        } catch {
            logger.error("Failed to persist item: \(error.localizedDescription)")
            // Roll back so we never keep an in-memory item whose payload is now orphaned.
            items.removeAll { $0.id == item.id }
            onPersistFailure()
            return
        }
        applyMaxItemsLimit()
    }

    /// Paste-from-history bookkeeping. Deliberately does NOT reorder (acceptance §16.8).
    func recordUse(of itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].lastUsedAt = Date()
        items[index].useCount += 1
        persistUpdate(items[index])
    }

    // MARK: - Item actions

    func delete(id: UUID) {
        items.removeAll { $0.id == id }
        do {
            try storage.delete(id: id)
            // Only after the row is gone — otherwise a failed row delete + deleted payload
            // would leave a live row whose bytes are gone (dead, unpasteable item).
            payloadStore?.delete(id: id)
        } catch {
            logger.error("Failed to delete item: \(error.localizedDescription)")
        }
    }

    func setPinned(id: UUID, _ pinned: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned = pinned
        do {
            try storage.setPinned(id: id, pinned)
        } catch {
            logger.error("Failed to pin item: \(error.localizedDescription)")
        }
        if !pinned {
            applyMaxItemsLimit()
        }
    }

    /// Clear History (spec §7): wipes rows AND rotates the encryption key. Pinned items kept
    /// by default are re-encrypted under the fresh key.
    ///
    /// Ordering is load-bearing: unpinned rows are wiped FIRST, while pinned rows stay on
    /// disk decryptable under the old key — so if rotation throws (Keychain failures are
    /// real), nothing the user asked to keep has been touched. Only after rotation succeeds
    /// are pinned rows re-encrypted, one delete+insert at a time (update() does not rewrite
    /// content_enc).
    func clearAll(includePinned: Bool) {
        let keep = includePinned ? [] : pinnedItems

        // Decrypt kept binary payloads under the OLD key BEFORE rotation — afterwards the
        // shared key is new and these files (still old-key on disk) can't be read. Held in
        // memory across the rotation; for the pathological "many large pinned images" case
        // this is a transient spike (documented).
        var keptPayloads: [UUID: Data] = [:]
        if let payloadStore {
            for item in keep where item.kind != .text {
                if let data = try? payloadStore.read(id: item.id) {
                    keptPayloads[item.id] = data
                } else {
                    logger.error("Kept payload missing before clear: \(item.id)")
                }
            }
        }

        do {
            try storage.deleteAll(keepPinned: !includePinned)
            try rotateEncryptionKey()
        } catch {
            logger.error("Clear history aborted: \(error.localizedDescription)")
            reload() // pinned rows + payloads are intact on disk under the unchanged key
            // Reclaim payload files whose (unpinned) rows were already deleted before the throw.
            payloadStore?.sweep(keeping: binaryItemIDs())
            return
        }

        // Re-encrypt kept items under the new key. Track which actually survived so the
        // in-memory set and the disk state never disagree (a row must never be left absent
        // while its bytes exist, nor present pointing at an unreadable payload).
        var survived: [ClipboardItem] = []
        for item in keep {
            // A kept binary item whose payload couldn't be carried across rotation is dropped
            // entirely — re-creating its row would point at an absent/old-key payload.
            if item.kind != .text, keptPayloads[item.id] == nil {
                logger.error("Dropping kept binary item with unreadable payload: \(item.id)")
                try? storage.delete(id: item.id) // remove the dead old-key row
                payloadStore?.delete(id: item.id)
                continue
            }
            do {
                // Re-encrypt the payload under the NEW key first, so the row never points at
                // an old-key (now unreadable) payload.
                if item.kind != .text, let data = keptPayloads[item.id] {
                    try payloadStore?.write(id: item.id, plaintext: data)
                }
                try storage.delete(id: item.id)
                try storage.insert(item) // re-encrypts content_enc / thumb_enc / manifest_enc
                survived.append(item)
            } catch {
                // The row may now be absent; drop the just-written new-key payload so it isn't
                // orphaned, and exclude the item so memory matches disk. Losing one item to a
                // disk error is preferable to a dead row or an orphaned payload.
                logger.error("Re-encrypt of kept item failed: \(error.localizedDescription)")
                if item.kind != .text { payloadStore?.delete(id: item.id) }
            }
        }
        // Reclaim payload files for the now-deleted unpinned (and dropped) binary items.
        payloadStore?.sweep(keeping: Set(survived.filter { $0.kind != .text }.map(\.id)))
        items = survived
    }

    // MARK: - Retention

    /// Runs at launch and daily (spec §7). Pinned items are exempt.
    func applyRetention(now: Date = Date()) {
        let days = retentionDays()
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        // Snapshot which binary payloads will be purged, before the rows go.
        let purgedBinaryIDs = items
            .filter { !$0.isPinned && $0.lastCapturedAt < cutoff && $0.kind != .text }
            .map(\.id)
        do {
            try storage.purge(olderThan: cutoff, keepPinned: true)
            // Only delete payloads for rows the purge actually removed.
            for id in purgedBinaryIDs { payloadStore?.delete(id: id) }
        } catch {
            logger.error("Retention purge failed: \(error.localizedDescription)")
            return // rows still on disk; leave their payloads alone
        }
        items.removeAll { !$0.isPinned && $0.lastCapturedAt < cutoff }
    }

    func applyMaxItemsLimit() {
        let limit = maxItems()
        guard limit > 0 else { return }
        // Pinned items are exempt from trimming; trim oldest unpinned beyond the cap.
        let unpinned = recentItems
        guard unpinned.count > limit else { return }
        let toRemove = unpinned.suffix(unpinned.count - limit)
        for item in toRemove {
            do {
                try storage.delete(id: item.id)
                payloadStore?.delete(id: item.id) // only after the row delete succeeded
            } catch {
                logger.error("Trim failed: \(error.localizedDescription)")
            }
        }
        let removeIDs = Set(toRemove.map(\.id))
        items.removeAll { removeIDs.contains($0.id) }
    }

    // MARK: - Search

    /// Case-insensitive substring search over kind-aware searchable text and the source app;
    /// pinned matches surface separately in the panel.
    func search(_ query: String) -> [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.filter { item in
            item.searchableText.localizedCaseInsensitiveContains(trimmed)
                || (item.sourceAppName?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    private func persistUpdate(_ item: ClipboardItem) {
        do {
            try storage.update(item)
        } catch {
            logger.error("Failed to update item: \(error.localizedDescription)")
        }
    }
}
