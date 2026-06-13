import CryptoKit
import Foundation
import Testing
@testable import ClipboardHistory

struct EncryptionTests {
    @Test func roundTrip() throws {
        let service = EncryptionService(key: SymmetricKey(size: .bits256))
        let plaintext = "secret clipboard content 🚀 with unicode"
        let blob = try service.encrypt(plaintext)
        #expect(try service.decrypt(blob) == plaintext)
        #expect(!blob.isEmpty)
    }

    @Test func ciphertextDoesNotContainPlaintext() throws {
        let service = EncryptionService(key: SymmetricKey(size: .bits256))
        let plaintext = "findable-marker-string"
        let blob = try service.encrypt(plaintext)
        #expect(blob.range(of: Data(plaintext.utf8)) == nil)
    }

    @Test func keyRotationMakesOldBlobsUndecryptable() throws {
        let service = EncryptionService(key: SymmetricKey(size: .bits256))
        let blob = try service.encrypt("before rotation")
        service.replaceKey(SymmetricKey(size: .bits256))
        #expect(throws: (any Error).self) {
            _ = try service.decrypt(blob)
        }
    }

    @Test func tamperedBlobFailsAuthentication() throws {
        let service = EncryptionService(key: SymmetricKey(size: .bits256))
        var blob = try service.encrypt("integrity matters")
        blob[blob.count - 1] ^= 0xFF
        #expect(throws: (any Error).self) {
            _ = try service.decrypt(blob)
        }
    }
}
