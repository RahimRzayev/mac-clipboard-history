import CryptoKit
import Foundation
import Testing
@testable import ClipboardHistory

struct DataCryptoTests {
    @Test func dataRoundTrip() throws {
        let service = EncryptionService(key: SymmetricKey(size: .bits256))
        let bytes = Data((0..<5000).map { UInt8($0 % 256) }) // non-UTF8 binary
        let blob = try service.encryptData(bytes)
        #expect(try service.decryptData(blob) == bytes)
    }

    @Test func emptyDataRoundTrip() throws {
        let service = EncryptionService(key: SymmetricKey(size: .bits256))
        let blob = try service.encryptData(Data())
        #expect(try service.decryptData(blob).isEmpty)
    }

    @Test func ciphertextDoesNotContainPlaintextBytes() throws {
        let service = EncryptionService(key: SymmetricKey(size: .bits256))
        let marker = Data("BINARY-MARKER-7f3a".utf8)
        let blob = try service.encryptData(marker)
        #expect(blob.range(of: marker) == nil)
    }

    @Test func decryptAfterRotationFails() throws {
        let service = EncryptionService(key: SymmetricKey(size: .bits256))
        let blob = try service.encryptData(Data("secret".utf8))
        service.replaceKey(SymmetricKey(size: .bits256))
        #expect(throws: (any Error).self) { _ = try service.decryptData(blob) }
    }

    @Test func tamperedBinaryBlobFails() throws {
        let service = EncryptionService(key: SymmetricKey(size: .bits256))
        var blob = try service.encryptData(Data("integrity".utf8))
        blob[blob.count - 1] ^= 0xFF
        #expect(throws: (any Error).self) { _ = try service.decryptData(blob) }
    }
}

struct PayloadStoreTests {
    private func makeStore() -> (PayloadStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PayloadTests-\(UUID().uuidString)", isDirectory: true)
        let store = PayloadStore(directory: dir, encryption: EncryptionService(key: SymmetricKey(size: .bits256)))
        return (store, dir)
    }

    @Test func writeReadRoundTrip() throws {
        let (store, _) = makeStore()
        let id = UUID()
        let data = Data((0..<2048).map { UInt8($0 % 256) })
        try store.write(id: id, plaintext: data)
        #expect(try store.read(id: id) == data)
    }

    @Test func readMissingThrows() {
        let (store, _) = makeStore()
        #expect(throws: PayloadError.self) { _ = try store.read(id: UUID()) }
    }

    @Test func deleteIsIdempotent() throws {
        let (store, _) = makeStore()
        let id = UUID()
        try store.write(id: id, plaintext: Data("x".utf8))
        store.delete(id: id)
        store.delete(id: id) // no throw
        #expect(throws: PayloadError.self) { _ = try store.read(id: id) }
    }

    @Test func writtenFileIsOwnerOnly() throws {
        let (store, dir) = makeStore()
        let id = UUID()
        try store.write(id: id, plaintext: Data("x".utf8))
        let path = dir.appendingPathComponent("\(id.uuidString).enc").path
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    @Test func sweepRemovesOrphansAndTmpButKeepsListed() throws {
        let (store, dir) = makeStore()
        let keep = UUID(), orphan = UUID()
        try store.write(id: keep, plaintext: Data("k".utf8))
        try store.write(id: orphan, plaintext: Data("o".utf8))
        try Data("leftover".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).tmp"))

        store.sweep(keeping: [keep])

        #expect((try? store.read(id: keep)) != nil)
        #expect((try? store.read(id: orphan)) == nil)
        let tmps = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "tmp" } ?? []
        #expect(tmps.isEmpty)
    }

    @Test func plaintextNeverOnDisk() throws {
        let (store, dir) = makeStore()
        let id = UUID()
        let secret = Data("super-secret-payload-marker".utf8)
        try store.write(id: id, plaintext: secret)
        let onDisk = try Data(contentsOf: dir.appendingPathComponent("\(id.uuidString).enc"))
        #expect(onDisk.range(of: secret) == nil)
    }
}
