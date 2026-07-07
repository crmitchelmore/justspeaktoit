import Foundation
import Security

// MARK: - iCloud Keychain sync configuration + availability
//
// Split out of `SecureStorage.swift` to keep that file within the length limit
// and to house the iCloud-Keychain-specific helpers together.

extension SecureStorageConfiguration {
    /// Builds a configuration that syncs secrets via iCloud Keychain **when the
    /// running build is entitled to**, and otherwise degrades to a safe,
    /// local-only configuration.
    ///
    /// `kSecAttrSynchronizable` (and a shared `accessGroup`) require the iCloud
    /// Keychain / keychain-access-group entitlement. App Store and development
    /// iOS builds have it; Developer-ID (non-App-Store) macOS builds do not and
    /// would fail with `errSecMissingEntitlement (-34018)`. This factory probes
    /// the capability at runtime so the same call site works everywhere.
    ///
    /// - Parameter accessGroup: shared keychain group enabling cross-app sync
    ///   (e.g. iOS ↔ macOS). Pass `nil` for same-app cross-device sync only.
    public static func iCloudSyncedIfAvailable(
        service: String,
        // swiftlint:disable:next inclusive_language
        masterAccount: String = "speak-app-secrets",
        accessGroup: String? = nil
    ) -> SecureStorageConfiguration {
        let canSync = KeychainSyncAvailability.isAvailable(accessGroup: accessGroup)
        return SecureStorageConfiguration(
            service: service,
            masterAccount: masterAccount,
            accessGroup: canSync ? accessGroup : nil,
            synchronizable: canSync
        )
    }
}

/// Detects whether this process may create iCloud-synchronized keychain items.
public enum KeychainSyncAvailability {
    /// Probes the keychain by attempting to add (and immediately delete) a throw
    /// away synchronizable item, optionally within `accessGroup`.
    ///
    /// Returns `false` when the build lacks the required entitlement (e.g.
    /// Developer-ID macOS, or a missing/incorrect keychain-access-group), so
    /// callers can fall back to local-only storage instead of failing writes.
    public static func isAvailable(accessGroup: String? = nil) -> Bool {
        let account = "sync-probe-\(UUID().uuidString)"
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.justspeaktoit.keychain-sync-probe",
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecValueData as String: Data("probe".utf8)
        ]
        if let accessGroup {
            addQuery[kSecAttrAccessGroup as String] = accessGroup
        }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { return false }

        var deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.justspeaktoit.keychain-sync-probe",
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
        if let accessGroup {
            deleteQuery[kSecAttrAccessGroup as String] = accessGroup
        }
        SecItemDelete(deleteQuery as CFDictionary)
        return true
    }
}
