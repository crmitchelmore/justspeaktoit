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
    static func defaultKeychainService(for channel: DistributionChannel) -> String {
        switch channel {
        case .direct:
            return "com.justspeaktoit.credentials"
        case .appStore:
            return "com.justspeaktoit.appstore.credentials"
        }
    }

    private let storage: SecureStorage
    private nonisolated let permissionsManager: PermissionsManager
    private nonisolated let appSettings: AppSettings

    init(
        permissionsManager: PermissionsManager,
        appSettings: AppSettings,
        keychainService: String = "com.justspeaktoit.credentials"
    ) {
        self.permissionsManager = permissionsManager
        self.appSettings = appSettings

        // The local Keychain is the vault for every Mac build. App Store builds
        // opt in to the separate passphrase-encrypted CloudKit sync layer; direct
        // builds remain local-only. Do not silently add iCloud Keychain as a third
        // API-key sync path.
        let configuration = SecureStorageConfiguration(
            service: keychainService,
            masterAccount: "speak-app-secrets",
            accessGroup: nil,
            synchronizable: false
        )

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[SecureAppStorage] Keychain Configuration:")
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

    func coreStorage() -> SecureStorage {
        storage
    }

    func hasSecret(identifier: String) async -> Bool {
        await storage.hasSecret(identifier: identifier)
    }

    func preloadTrackedSecrets() async {
        await storage.preload()
    }
}
