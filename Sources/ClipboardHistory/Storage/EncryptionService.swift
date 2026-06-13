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

    /// Returns the AES-GCM combined blob (nonce + ciphertext + tag).
    func encrypt(_ plaintext: String) throws -> Data {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else { throw EncryptionError.sealFailed }
        return combined
    }

    func decrypt(_ blob: Data) throws -> String {
        let box = try AES.GCM.SealedBox(combined: blob)
        let data = try AES.GCM.open(box, using: key)
        guard let string = String(data: data, encoding: .utf8) else { throw EncryptionError.notUTF8 }
        return string
    }
}
