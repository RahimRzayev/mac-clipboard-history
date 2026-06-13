import Foundation

/// In-memory storage. Used by unit tests, and as a degraded-mode fallback if the
/// SQLite database cannot be opened (history then doesn't survive relaunch).
final class MemoryClipboardStorage: ClipboardStorage {
    private(set) var items: [UUID: ClipboardItem] = [:]

    func insert(_ item: ClipboardItem) throws {
        items[item.id] = item
    }

    func update(_ item: ClipboardItem) throws {
        // Match SQLite UPDATE semantics: a missing row is a no-op, not an upsert —
        // this is the unit-test double, so divergence here hides real-store bugs.
        guard items[item.id] != nil else { return }
        items[item.id] = item
    }

    func delete(id: UUID) throws {
        items.removeValue(forKey: id)
    }

    func deleteAll(keepPinned: Bool) throws {
        if keepPinned {
            items = items.filter { $0.value.isPinned }
        } else {
            items.removeAll()
        }
    }

    func purge(olderThan cutoff: Date, keepPinned: Bool) throws {
        items = items.filter { _, item in
            if keepPinned && item.isPinned { return true }
            return item.lastCapturedAt >= cutoff
        }
    }

    func fetchAll(limit: Int?) throws -> [ClipboardItem] {
        // Same ordering + tie-breakers as the SQLite backend.
        let sorted = items.values.sorted {
            if $0.lastCapturedAt != $1.lastCapturedAt { return $0.lastCapturedAt > $1.lastCapturedAt }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        if let limit {
            return Array(sorted.prefix(limit))
        }
        return sorted
    }

    func setPinned(id: UUID, _ pinned: Bool) throws {
        items[id]?.isPinned = pinned
    }
}
