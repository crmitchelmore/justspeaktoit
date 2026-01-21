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
        
        // Check if we have the keychain-access-groups entitlement
        // Developer ID builds may not have it (stripped for CI)
        let hasAccessGroupEntitlement = Self.hasKeychainAccessGroupEntitlement()
        
        let configuration = SecureStorageConfiguration(
            service: "com.justspeaktoit.credentials",
            masterAccount: "speak-app-secrets",
            // Only use access group if we have the entitlement
            accessGroup: hasAccessGroupEntitlement ? "8X4ZN58TYH.com.justspeaktoit.shared" : nil,
            // Only enable sync if we have access group
            synchronizable: hasAccessGroupEntitlement
        )
        
        self.storage = SecureStorage(
            configuration: configuration,
            permissionsChecker: PermissionsManagerBridge(permissionsManager: permissionsManager),
            identifierRegistry: appSettings
        )
    }
    
    /// Check if the app has keychain-access-groups entitlement
    private static func hasKeychainAccessGroupEntitlement() -> Bool {
        // Try a test keychain operation with access group
        // If it fails with errSecMissingEntitlement (-34018), we don't have the entitlement
        let testQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.justspeaktoit.entitlement-check",
            kSecAttrAccount as String: "test",
            kSecAttrAccessGroup as String: "8X4ZN58TYH.com.justspeaktoit.shared",
            kSecReturnData as String: false
        ]
        
        let status = SecItemCopyMatching(testQuery as CFDictionary, nil)
        
        // errSecMissingEntitlement = -34018 means we don't have the entitlement
        // errSecItemNotFound = -25300 means we have the entitlement but no item exists
        // Other errors also indicate we can likely proceed without access group
        if status == errSecMissingEntitlement {
            print("[SecureAppStorage] No keychain-access-groups entitlement, using app-local keychain")
            return false
        }
        
        print("[SecureAppStorage] Keychain access group entitlement available")
        return true
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
