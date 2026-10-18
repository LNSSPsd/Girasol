import Foundation
import Security

extension OAuthClient {
    /// The token's item, in Girasol's own group (`OPKeychainGroup`): the app
    /// can read Opaline's group too, where the same item may exist.
    private func keychainQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        if let group = OPKeychainGroup.own {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    func saveToKeychain(_ tokens: OAuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else {
            return
        }
        let query = keychainQuery()
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        // Default accessibility is `WhenUnlocked`, which makes the tokens
        // unreadable during a background fetch on a locked device — the app
        // then decides the user is signed out and builds the sign-in screen.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Rewrites an existing item so it picks up the accessibility above.
    /// The flag is only set once the rewrite actually happened: on a locked
    /// device the read fails, and the migration must survive to try again.
    func migrateKeychainAccessibilityIfNeeded() {
        let key = UserDefaultsKeys.Migration.keychainAfterFirstUnlock
        guard !UserDefaults.standard.bool(forKey: key),
              let tokens = loadFromKeychain()
        else {
            return
        }
        saveToKeychain(tokens)
        UserDefaults.standard.set(true, forKey: key)
        AppLog.auth("keychain migrated to after-first-unlock")
    }
    func loadFromKeychain() -> OAuthTokens? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(
            query as CFDictionary,
            &result
        ) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }
        return try? JSONDecoder().decode(
            OAuthTokens.self,
            from: data
        )
    }
    func deleteFromKeychain() {
        let query = keychainQuery()
        SecItemDelete(query as CFDictionary)
    }
}
