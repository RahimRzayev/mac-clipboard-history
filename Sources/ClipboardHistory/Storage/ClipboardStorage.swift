import Foundation

/// Item-level persistence operations (spec §7). Deliberately NOT loadAll/saveAll —
/// backends map these to real row operations so the SQLite engine actually pays off.
protocol ClipboardStorage {
    func insert(_ item: ClipboardItem) throws
    /// Updates mutable fields (lastCapturedAt / lastUsedAt / useCount / isPinned).
    func update(_ item: ClipboardItem) throws
    func delete(id: UUID) throws
    func deleteAll(keepPinned: Bool) throws
    /// Removes unpinned items whose lastCapturedAt is older than the cutoff.
    func purge(olderThan cutoff: Date, keepPinned: Bool) throws
    /// Newest first by lastCapturedAt, decrypted.
    func fetchAll(limit: Int?) throws -> [ClipboardItem]
    func setPinned(id: UUID, _ pinned: Bool) throws
}
