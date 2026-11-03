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
    ///
    /// Reports non-trivial Keychain status codes (e.g. `errSecAuthFailed`,
    /// `errSecInteractionNotAllowed`) via `NSLog` without ever logging the
    /// credential value itself.
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

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                NSLog("Keychain: Failed to decode stored API key data")
                return nil
            }
            return string

        case errSecItemNotFound:
            // No stored key — this is a normal first-launch condition.
            return nil

        default:
            // Report the status code (e.g. -25308 errSecAuthFailed,
            // -25309 errSecInteractionNotAllowed) without logging any
            // credential material.
            NSLog("Keychain: Failed to load API key (status: \(status))")
            return nil
        }
    }

    /// Stores (or updates) the API key in the Keychain.
    ///
    /// Uses `SecItemUpdate` when an existing item is found (preserving its
    /// access-control list and authorization state) and falls back to
    /// `SecItemAdd` only when no item exists yet. This avoids the
    /// delete-and-recreate pattern, which destroys the item's ACL and forces
    /// the user to re-authorize on every launch.
    ///
    /// - Parameter key: The API key to store. Pass an empty string to delete the stored key.
    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)

        // An empty key means "clear the stored credential".
        guard !trimmed.isEmpty else {
            delete()
            return
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Check whether an item already exists for this service/account pair.
        var existing: AnyObject?
        let lookupStatus = SecItemCopyMatching(baseQuery as CFDictionary, &existing)

        if lookupStatus == errSecSuccess {
            // Item exists — update only the value data. The existing item's
            // access-control list (ACL) and any prior user authorization are
            // preserved, so no re-prompt is required on subsequent launches.
            let updateAttributes: [String: Any] = [
                kSecValueData as String: Data(trimmed.utf8),
            ]
            let status = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
            if status != errSecSuccess {
                NSLog("Keychain: Failed to update API key (status: \(status))")
            }
        } else if lookupStatus == errSecItemNotFound {
            // No existing item — create a new one.
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: Data(trimmed.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            if status != errSecSuccess {
                NSLog("Keychain: Failed to add API key (status: \(status))")
            }
        } else {
            // Unexpected lookup failure (e.g. errSecInteractionNotAllowed,
            // errSecAuthFailed). Report the status code without logging
            // any credential material.
            NSLog("Keychain: Failed to look up existing API key (status: \(lookupStatus))")
        }
    }

    /// Deletes the stored API key from the Keychain.
    ///
    /// Reports non-trivial status codes without logging credential values.
    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("Keychain: Failed to delete API key (status: \(status))")
        }
    }
}
