import Foundation
import Security
import os

/// The keychain items behind one `SecureStorage`: the master account's
/// legacy compatibility record, the versioned overflow item, the backup of a
/// newer-version payload, and the per-secret items written before secrets
/// were consolidated. It only reads and writes items; the secrets cache and
/// the migration policy stay with `SecureStorage`.
struct SecureStorageKeychainItems: Sendable {
    private static let logger = SpeakLogger.logger(category: "SecureStorage")

    let configuration: SecureStorageConfiguration

    /// The overflow account holding the versioned payload for values the
    /// legacy compatibility record cannot represent (issue #672).
    var overflowAccount: String { configuration.masterAccount + ".v2" }

    /// Where a payload with an unknown newer version marker is preserved
    /// before this build writes anything (issue #672).
    var unsupportedBackupAccount: String { configuration.masterAccount + ".unsupported-backup" }

    /// The accessibility class the master item actually carries, read back
    /// off the item with `kSecReturnData` off; nil when there is no item.
    func storedAccessibility() -> CaptureHealthAccessibility? {
        var query = baseQuery(account: configuration.masterAccount)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard KeychainAccess.copyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any],
              let accessible = attributes[kSecAttrAccessible as String] as? String
        else { return nil }
        return CaptureHealthAccessibility(secAttrAccessible: accessible)
    }

    func readPayload(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = KeychainAccess.copyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let payload = String(data: data, encoding: .utf8)
        else {
            throw SecureStorageError.unexpectedStatus(status)
        }
        if configuration.accessibility == .afterFirstUnlock {
            do {
                try KeychainAccessibilityMigration.migrate(query: baseQuery(account: account), expectedData: data)
            } catch {
                // A readable credential stays usable even if this OS rejects the
                // attribute update. Leave the original item intact and retry on reload.
                Self.logger.error(
                    "Credential accessibility migration failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return payload
    }

    /// The master account's payload under an older service name, or nil when
    /// that service has no item.
    func readLegacyServicePayload(service legacyService: String) throws -> String? {
        var query = baseQuery(account: configuration.masterAccount)
        query[kSecAttrService as String] = legacyService
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = KeychainAccess.copyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess,
              let data = item as? Data,
              let payload = String(data: data, encoding: .utf8)
        else {
            throw SecureStorageError.unexpectedStatus(status)
        }
        return payload
    }

    /// Persists `cache` under the documented mixed-version contract
    /// (issue #672): the master account carries the legacy-format
    /// compatibility record for every representable entry, the overflow
    /// account carries the versioned payload for the rest. If the second
    /// write fails, the first is rolled back so the two accounts never
    /// disagree about a half-applied save.
    func write(cache: [String: String]) throws {
        let compatibility = SecureStorage.serializeLegacyCompatibilityRecord(cache: cache)
        let overflow = SecureStorage.serializeOverflowPayload(cache: cache)

        let previousCompatibility = try readPayload(account: configuration.masterAccount)
        try writePayload(compatibility, account: configuration.masterAccount)
        do {
            try writePayload(overflow, account: overflowAccount)
        } catch {
            try? writePayload(previousCompatibility ?? "", account: configuration.masterAccount)
            throw error
        }
    }

    func writePayload(_ payload: String, account: String) throws {
        let query = baseQuery(account: account)

        if payload.isEmpty {
            let deleteStatus = KeychainAccess.delete(query as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw SecureStorageError.unexpectedStatus(deleteStatus)
            }
            return
        }

        let data = Data(payload.utf8)
        var attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: account
        ]

        if let accessibility = configuration.keychainAccessibility {
            attributesToUpdate[kSecAttrAccessible as String] = accessibility
        }
        if configuration.accessGroup != nil && configuration.synchronizable {
            attributesToUpdate[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }

        let status = KeychainAccess.update(query as CFDictionary, attributesToUpdate as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrLabel as String] = account

            if let accessibility = configuration.keychainAccessibility {
                addQuery[kSecAttrAccessible as String] = accessibility
            }
            if configuration.accessGroup != nil && configuration.synchronizable {
                addQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
            }

            let addStatus = KeychainAccess.add(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                Self.logger.debug("ERROR: SecItemAdd failed with \(addStatus, privacy: .private)")
                throw SecureStorageError.unexpectedStatus(addStatus)
            }
        } else if status != errSecSuccess {
            Self.logger.debug("ERROR: SecItemUpdate failed with \(status, privacy: .private)")
            throw SecureStorageError.unexpectedStatus(status)
        }
    }

    // MARK: - Per-secret items from before consolidation

    /// Accounts stored under this service, one per secret before secrets
    /// were consolidated into one payload.
    func legacyAccounts() throws -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        if let accessGroup = configuration.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: CFTypeRef?
        let status = KeychainAccess.copyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return []
        }

        guard status == errSecSuccess else {
            throw SecureStorageError.unexpectedStatus(status)
        }

        guard let array = result as? [[String: Any]] else { return [] }
        return array.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// One per-secret item, or nil when it does not exist.
    func readLegacySecret(identifier: String) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true
        ]

        if let accessGroup = configuration.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var item: CFTypeRef?
        let status = KeychainAccess.copyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw SecureStorageError.unexpectedStatus(status)
        }
        return value
    }

    func deleteLegacySecret(identifier: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
            kSecAttrAccount as String: identifier
        ]

        if let accessGroup = configuration.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        KeychainAccess.delete(query as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
            kSecAttrAccount as String: account
        ]

        if let accessGroup = configuration.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        if configuration.synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }

        return query
    }
}
