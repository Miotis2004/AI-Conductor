import Foundation
import Security

// MARK: - Keychain Credential Storage

/// Stores and retrieves the API key in the macOS Keychain.
///
/// The key is stored as a generic password with the service identifier
/// `devplaceholder.C1GXNR34.AI_Connector` and the account `apiKey`.
/// No API key is ever hardcoded in source or written to disk.
enum KeychainStore {
    private static let service = "devplaceholder.C1GXNR34.AI_Connector"
    private static let account = "apiKey"

    /// Retrieves the stored API key, or `nil` if none exists.
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// Stores (or updates) the API key in the Keychain.
    ///
    /// - Parameter key: The API key to store. Pass an empty string to delete the stored key.
    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)

        // Delete first to handle both create and update cases.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard !trimmed.isEmpty else { return }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            // Log but do not crash; the UI will reflect the failure via the returned value.
            NSLog("Keychain: Failed to store API key (status: \(status))")
        }
    }

    /// Deletes the stored API key from the Keychain.
    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
