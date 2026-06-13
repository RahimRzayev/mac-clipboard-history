import Foundation

enum PayloadError: Error {
    case missing
}

/// Stores binary payloads (image/file bytes) as per-item AES-GCM-encrypted sidecar files,
/// one per item keyed by id: `<AppSupport>/<bundleID>/payloads/<id>.enc`. The path is always
/// derived from the id, so it can never desync with the database row — orphans are reclaimed
/// by `sweep`. Uses the SAME shared EncryptionService as the row content, so one key rotation
/// (Clear History) covers rows and payloads together.
///
/// Plain struct (not an actor): callers decide threading. Capture-time write and paste-time
/// read are dispatched off the main actor by ClipboardStore; the methods themselves are
/// synchronous and self-contained.
struct PayloadStore {
    let directory: URL
    let encryption: EncryptionService

    private static let fileExtension = "enc"

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(Self.fileExtension)")
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // createDirectory only applies permissions when it creates the dir; tighten anyway.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Encrypts and writes atomically (temp file + replace), then restricts to 0600.
    func write(id: UUID, plaintext: Data) throws {
        try ensureDirectory()
        let blob = try encryption.encryptData(plaintext)
        let finalURL = url(for: id)
        let tempURL = directory.appendingPathComponent("\(id.uuidString).tmp")
        try blob.write(to: tempURL, options: [.atomic])
        // replaceItemAt removes the temp source and moves it into place atomically.
        _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tempURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalURL.path)
    }

    func read(id: UUID) throws -> Data {
        let fileURL = url(for: id)
        guard let blob = try? Data(contentsOf: fileURL) else { throw PayloadError.missing }
        return try encryption.decryptData(blob)
    }

    /// Best-effort, idempotent — a missing file for an absent row is harmless.
    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Removes every `<uuid>.enc` whose id is not in `keeping`, plus any leftover `*.tmp`
    /// files from interrupted writes. The launch-time + post-clear orphan GC.
    func sweep(keeping: Set<UUID>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            if entry.pathExtension == "tmp" {
                try? fm.removeItem(at: entry)
                continue
            }
            guard entry.pathExtension == Self.fileExtension else { continue }
            let stem = entry.deletingPathExtension().lastPathComponent
            if let id = UUID(uuidString: stem), keeping.contains(id) { continue }
            try? fm.removeItem(at: entry)
        }
    }
}
