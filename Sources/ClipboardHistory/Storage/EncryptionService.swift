import CryptoKit
import Foundation

enum EncryptionError: Error {
    case sealFailed
    case notUTF8
}

/// AES-GCM encryption for item content at rest. Reference type on purpose:
/// Clear History rotates the key in place (spec §7) and storage shares this instance.
final class EncryptionService {
    private(set) var key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    func replaceKey(_ newKey: SymmetricKey) {
        key = newKey
    }

    /// Returns the AES-GCM combined blob (nonce + ciphertext + tag) for raw bytes.
    /// Used for binary payloads (images/files), thumbnails, and file manifests.
    func encryptData(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw EncryptionError.sealFailed }
        return combined
    }

    func decryptData(_ blob: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: blob)
        return try AES.GCM.open(box, using: key)
    }

    /// Returns the AES-GCM combined blob (nonce + ciphertext + tag) for a string.
    func encrypt(_ plaintext: String) throws -> Data {
        try encryptData(Data(plaintext.utf8))
    }

    func decrypt(_ blob: Data) throws -> String {
        let data = try decryptData(blob)
        guard let string = String(data: data, encoding: .utf8) else { throw EncryptionError.notUTF8 }
        return string
    }
}
