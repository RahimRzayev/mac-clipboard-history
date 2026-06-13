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
        maxItems: @escaping () -> Int = { 500 },
        retentionDays: @escaping () -> Int = { 30 },
        rotateEncryptionKey: @escaping () throws -> Void = {}
    ) {
        self.storage = storage
        self.maxItems = maxItems
        self.retentionDays = retentionDays
        self.rotateEncryptionKey = rotateEncryptionKey
        reload()
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
        if let index = items.firstIndex(where: { $0.dedupKey == key }) {
            var existing = items[index]
            existing.lastCapturedAt = Date()
            existing.useCount += 1
            items.remove(at: index)
            items.insert(existing, at: 0)
            persistUpdate(existing)
            return
        }

        let item = ClipboardItem(
            content: content,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName
        )
        items.insert(item, at: 0)
        do {
            try storage.insert(item)
        } catch {
            logger.error("Failed to persist item: \(error.localizedDescription)")
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
        do {
            try storage.deleteAll(keepPinned: !includePinned)
            try rotateEncryptionKey()
        } catch {
            logger.error("Clear history aborted: \(error.localizedDescription)")
            reload() // pinned rows are intact on disk under the unchanged key
            return
        }
        for item in keep {
            do {
                try storage.delete(id: item.id)
                try storage.insert(item) // insert encrypts under the NEW key
            } catch {
                // Keep the item in memory even if its disk rewrite failed — never drop
                // user-kept data because of an I/O error.
                logger.error("Re-encrypt of pinned item failed: \(error.localizedDescription)")
            }
        }
        items = keep
    }

    // MARK: - Retention

    /// Runs at launch and daily (spec §7). Pinned items are exempt.
    func applyRetention(now: Date = Date()) {
        let days = retentionDays()
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        do {
            try storage.purge(olderThan: cutoff, keepPinned: true)
        } catch {
            logger.error("Retention purge failed: \(error.localizedDescription)")
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
            } catch {
                logger.error("Trim failed: \(error.localizedDescription)")
            }
        }
        let removeIDs = Set(toRemove.map(\.id))
        items.removeAll { removeIDs.contains($0.id) }
    }

    // MARK: - Search

    /// Case-insensitive substring search; pinned matches surface separately in the panel.
    func search(_ query: String) -> [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.filter { $0.content.localizedCaseInsensitiveContains(trimmed) }
    }

    private func persistUpdate(_ item: ClipboardItem) {
        do {
            try storage.update(item)
        } catch {
            logger.error("Failed to update item: \(error.localizedDescription)")
        }
    }
}
