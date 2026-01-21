import Foundation
import Security
import SpeakCore

// MARK: - Legacy Error Type (kept for compatibility)

enum SecureAppStorageError: LocalizedError {
    case permissionDenied
    case valueNotFound
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Keychain access was denied. Please review your Security & Privacy settings."
        case .valueNotFound:
            return "No value found for the requested identifier."
        case .unexpectedStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Keychain returned status \(status)."
        }
    }

    init(from error: SecureStorageError) {
        switch error {
        case .permissionDenied:
            self = .permissionDenied
        case .valueNotFound:
            self = .valueNotFound
        case .unexpectedStatus(let status):
            self = .unexpectedStatus(status)
        }
    }
}

// MARK: - Permissions Bridge

/// Bridges PermissionsManager to SpeakCore's KeychainPermissionsChecking protocol
final class PermissionsManagerBridge: KeychainPermissionsChecking, @unchecked Sendable {
    private let permissionsManager: PermissionsManager

    init(permissionsManager: PermissionsManager) {
        self.permissionsManager = permissionsManager
    }

    func ensureKeychainAccess(forService service: String) async -> Bool {
        await permissionsManager.ensureKeychainAccess(forService: service)
    }
}

// MARK: - AppSettings Bridge

/// Makes AppSettings conform to APIKeyIdentifierRegistry
extension AppSettings: APIKeyIdentifierRegistry {}

// MARK: - SecureAppStorage (Thin Wrapper)

/// macOS-specific wrapper around SpeakCore's SecureStorage.
/// Maintains the existing API for backward compatibility.
actor SecureAppStorage {
    private let storage: SecureStorage
    private nonisolated let permissionsManager: PermissionsManager
    private nonisolated let appSettings: AppSettings

    init(permissionsManager: PermissionsManager, appSettings: AppSettings) {
        self.permissionsManager = permissionsManager
        self.appSettings = appSettings
        
        // Check if we can use iCloud Keychain sync (kSecAttrSynchronizable)
        // Developer ID builds cannot use this - it requires keychain-access-groups entitlement
        let canUseSync = Self.hasKeychainSyncEntitlement()
        
        // IMPORTANT: For Developer ID (non-App Store) builds, we MUST NOT use:
        // - kSecAttrSynchronizable (requires keychain-access-groups entitlement) - causes -34018
        // - kSecAttrAccessGroup (requires keychain-access-groups entitlement in some cases)
        let configuration = SecureStorageConfiguration(
            service: "com.justspeaktoit.credentials",
            masterAccount: "speak-app-secrets",
            // Don't use access group for Developer ID - not needed and may cause issues
            accessGroup: nil,
            // Only enable sync if we verified the entitlement exists
            synchronizable: canUseSync
        )
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[SecureAppStorage] Keychain Configuration:")
        print("  canUseSync: \(canUseSync)")
        print("  accessGroup: \(configuration.accessGroup ?? "nil")")
        print("  synchronizable: \(configuration.synchronizable)")
        print("  service: \(configuration.service)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        self.storage = SecureStorage(
            configuration: configuration,
            permissionsChecker: PermissionsManagerBridge(permissionsManager: permissionsManager),
            identifierRegistry: appSettings
        )
    }
    
    /// Check if the app can use iCloud keychain sync by testing kSecAttrSynchronizable.
    /// Developer ID (non-App Store) builds cannot use synchronizable items.
    private static func hasKeychainSyncEntitlement() -> Bool {
        let testService = "com.justspeaktoit.entitlement-check"
        let testAccount = "sync-test-\(UUID().uuidString)"
        
        // Test with kSecAttrSynchronizable - THIS is what requires the entitlement
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
            kSecAttrAccount as String: testAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecValueData as String: "test".data(using: .utf8)!
        ]
        
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        
        // Clean up if we succeeded
        if addStatus == errSecSuccess {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: testService,
                kSecAttrAccount as String: testAccount,
                kSecAttrSynchronizable as String: kCFBooleanTrue!
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            print("[SecureAppStorage] iCloud Keychain sync entitlement available")
            return true
        }
        
        // errSecMissingEntitlement (-34018) means we can't use synchronizable
        print("[SecureAppStorage] No iCloud Keychain sync entitlement (status: \(addStatus)), disabling sync")
        return false
    }

    func storeSecret(_ value: String, identifier: String, label _: String? = nil) async throws {
        do {
            try await storage.storeSecret(value, identifier: identifier)
        } catch let error as SecureStorageError {
            throw SecureAppStorageError(from: error)
        }
    }

    func secret(identifier: String) async throws -> String {
        do {
            return try await storage.secret(identifier: identifier)
        } catch let error as SecureStorageError {
            throw SecureAppStorageError(from: error)
        }
    }

    func removeSecret(identifier: String) async throws {
        do {
            try await storage.removeSecret(identifier: identifier)
        } catch let error as SecureStorageError {
            throw SecureAppStorageError(from: error)
        }
    }

    func knownIdentifiers() async -> [String] {
        await storage.knownIdentifiers()
    }

    func hasSecret(identifier: String) async -> Bool {
        await storage.hasSecret(identifier: identifier)
    }

    func preloadTrackedSecrets() async {
        await storage.preload()
    }
}
