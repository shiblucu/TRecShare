import Foundation
import Security

/// Stores secrets (access keys, tokens) in the login Keychain, never in UserDefaults.
/// Items are only readable on this Mac and only after the first unlock.
enum Keychain {
    enum Key: String, CaseIterable {
        case spacesSecret = "spaces.secretKey"
        case driveClientSecret = "drive.clientSecret"
        case driveRefreshToken = "drive.refreshToken"
        case serverToken = "server.httpToken"
    }

    private static let service = (Bundle.main.bundleIdentifier ?? "com.tawfiq.scrcapkit") + ".secrets"

    static func get(_ key: Key) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves the value, or deletes the item when the value is empty.
    @discardableResult
    static func set(_ value: String?, for key: Key) -> Bool {
        guard let value, !value.isEmpty else { return delete(key) }
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        if status != errSecItemNotFound { Log.app.error("Keychain update failed: \(status)") }
        var add = baseQuery(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess { Log.app.error("Keychain add failed: \(addStatus)") }
        return addStatus == errSecSuccess
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func has(_ key: Key) -> Bool { !(get(key) ?? "").isEmpty }

    private static func baseQuery(_ key: Key) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue]
    }
}
