import Foundation
import Security

struct StoredCredential: Codable {
    let userID: UUID
    let nickname: String
    let token: String
    let isDemoAccount: Bool
}
protocol CredentialStore { func load() throws -> StoredCredential?; func save(_ credential: StoredCredential) throws; func clear() throws }
struct KeychainCredentialStore: CredentialStore {
    var account = "https://drivesave.nuhylabs.com"
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.hackpsu.driveandsave.auth", kSecAttrAccount as String: account] }
    func load() throws -> StoredCredential? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw BackendError.keychain(status) }
        return try JSONDecoder().decode(StoredCredential.self, from: data)
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BackendError.keychain(status) }
    }
    func save(_ credential: StoredCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard status == errSecSuccess else { throw BackendError.keychain(status) }
        } else if updated != errSecSuccess { throw BackendError.keychain(updated) }
    }
}
