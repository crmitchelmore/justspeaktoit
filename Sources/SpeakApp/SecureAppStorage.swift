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
        
        let configuration = SecureStorageConfiguration(
            service: "com.github.speakapp.credentials",
            masterAccount: "speak-app-secrets",
            accessGroup: nil,  // Will be set when enabling sync
            synchronizable: false
        )
        
        self.storage = SecureStorage(
            configuration: configuration,
            permissionsChecker: PermissionsManagerBridge(permissionsManager: permissionsManager),
            identifierRegistry: appSettings
        )
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
