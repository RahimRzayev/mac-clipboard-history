import CryptoKit
import Foundation
import Security

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
}

/// Stores the AES-256 history encryption key as a generic password in the user's login
/// keychain. It is never synced to iCloud Keychain because kSecAttrSynchronizable is never
/// set (the macOS file-based keychain ignores kSecAttrAccessible entirely; the data
/// protection keychain that honors it requires kSecUseDataProtectionKeychain plus an
/// application-identifier entitlement — adopt that when signing with Developer ID,
/// see spec §2.1).
struct KeychainKeyStore {
    let service: String
    let account = "history-encryption-key"

    func loadOrCreateKey() throws -> SymmetricKey {
        if let data = try load() {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let status = add(key.withUnsafeBytes { Data($0) })
        if status == errSecDuplicateItem {
            // Lost a first-launch race with another instance — the winner's key is the key.
            if let data = try load() {
                return SymmetricKey(data: data)
            }
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        return key
    }

    /// Replaces the stored key in place (SecItemUpdate), so a failed rotation leaves the
    /// old key intact and every existing row still decryptable. Delete-then-add would have
    /// a window where the keychain holds NO key — a crash there silently orphans the whole
    /// encrypted history on next launch.
    func rotateKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            status = add(data)
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        return key
    }

    private func load() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return data
    }

    private func add(_ data: Data) -> OSStatus {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        return SecItemAdd(attributes as CFDictionary, nil)
    }
}
