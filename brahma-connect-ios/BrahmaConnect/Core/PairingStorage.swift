import Foundation
import Security

/// Keychain-backed storage, replacing Android's EncryptedSharedPreferences.
final class PairingStorage {
    static let shared = PairingStorage()

    private let service = "com.brahma.connect.secure"
    private let credentialKey = "device_credential"
    private let offerKey = "last_pairing_offer"

    func saveCredential(_ credential: DeviceCredential) {
        if let data = try? JSONEncoder().encode(credential) { write(data, for: credentialKey) }
    }

    func loadCredential() -> DeviceCredential? {
        guard let data = read(credentialKey) else { return nil }
        return try? JSONDecoder().decode(DeviceCredential.self, from: data)
    }

    func clearCredential() {
        delete(credentialKey)
    }

    func saveGatewayHint(_ offer: PairingOffer) {
        if let data = try? JSONEncoder().encode(offer) { write(data, for: offerKey) }
    }

    func loadGatewayHint() -> PairingOffer? {
        guard let data = read(offerKey) else { return nil }
        return try? JSONDecoder().decode(PairingOffer.self, from: data)
    }

    func clearGatewayHint() {
        delete(offerKey)
    }

    // MARK: - Keychain

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private func write(_ data: Data, for key: String) {
        delete(key)
        var query = baseQuery(key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    private func read(_ key: String) -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func delete(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }
}
