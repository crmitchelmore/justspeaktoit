#if os(iOS)
import Foundation
import Security
import SpeakCore

// MARK: - Legacy migration

extension AppSettings {
    // MARK: - Legacy migration

    /// One-time migration of API keys from the pre-unification iOS keychain
    /// locations (raw per-account items and the old ElevenLabs SecureStorage,
    /// both under service `com.speak.ios.credentials`) into the canonical,
    /// iCloud-syncable store. Additive and idempotent: legacy items are read but
    /// never deleted, and each key is only migrated when the new store lacks it.
    static func migrateLegacyKeysIfNeeded() async {
        guard ReleaseTrain.current == .stable else { return }
        let existing = Set(await canonicalCredentialStorage.knownIdentifiers())

        for identifier in [deepgramKeyID, openRouterKeyID, openAIKeyID] where !existing.contains(identifier) {
            if let legacy = legacyRawSecret(account: identifier), !legacy.isEmpty {
                try? await canonicalCredentialStorage.storeSecret(legacy, identifier: identifier)
            }
        }

        if !existing.contains(elevenLabsKeyID) {
            let legacyStore = SecureStorage(
                configuration: SecureStorageConfiguration(service: "com.speak.ios.credentials")
            )
            if let key = try? await legacyStore.secret(identifier: elevenLabsKeyID), !key.isEmpty {
                try? await canonicalCredentialStorage.storeSecret(key, identifier: elevenLabsKeyID)
            }
        }
    }

    /// Reads a value from the legacy raw per-account keychain items.
    private static func legacyRawSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.speak.ios.credentials",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        guard KeychainAccess.copyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }
}
#endif
