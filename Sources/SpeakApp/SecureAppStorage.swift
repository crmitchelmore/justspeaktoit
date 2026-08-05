import Foundation
import os.log
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

/// AppSettings acts as the registry for known API-key identifiers so
/// SecureStorage can validate writes without coupling the core type to
/// app-layer storage. Conformance is via empty extension to keep the
/// registry surface minimal — no app logic leaks into SpeakCore.
extension AppSettings: APIKeyIdentifierRegistry {}

// Explicit registry adapter for tests: avoids forcing test doubles to
// inherit from AppSettings. Marked @MainActor to match the protocol; tests
// that need it off the main actor can create it inside `MainActor.run`.
@MainActor
final class InMemoryIdentifierRegistry: APIKeyIdentifierRegistry {
    private var identifiers: Set<String>
    init(identifiers: Set<String> = []) { self.identifiers = identifiers }
    func registerAPIKeyIdentifier(_ identifier: String) { identifiers.insert(identifier) }
    func removeAPIKeyIdentifier(_ identifier: String) { identifiers.remove(identifier) }
    var trackedAPIKeyIdentifiers: [String] { Array(identifiers) }
}

// MARK: - SecureAppStorage (Thin Wrapper)

/// macOS-specific wrapper around SpeakCore's SecureStorage.
/// Maintains the existing API for backward compatibility.
actor SecureAppStorage {
    private let storage: SecureStorage
    private nonisolated let permissionsManager: PermissionsManager
    private nonisolated let appSettings: AppSettings

    init(
        permissionsManager: PermissionsManager,
        appSettings: AppSettings,
        keychainService: String = "com.github.speakapp.credentials"
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
            legacyServices: ["com.justspeaktoit.credentials"],
            accessGroup: nil,
            synchronizable: false
        )

        if ProcessInfo.processInfo.environment["SPEAK_DEBUG_KEYCHAIN"] == "1" {
            Logger(subsystem: "com.github.speakapp", category: "SecureAppStorage").debug(
                "Keychain config — service: \(configuration.service, privacy: .public) synchronizable: \(configuration.synchronizable, privacy: .public) accessGroup: \(configuration.accessGroup ?? "nil", privacy: .public)"
            )
        }

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

    @discardableResult
    func preloadTrackedSecrets() async -> Bool {
        await storage.preloadAndReportSuccess()
    }
}
