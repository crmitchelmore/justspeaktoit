import Foundation
import os

// MARK: - Secure Storage Actor

/// Cross-platform secure storage for API keys and secrets.
/// Uses Keychain Services on both macOS and iOS.
public actor SecureStorage {
    private static let logger = SpeakLogger.logger(category: "SecureStorage")

    public static let didChangeSecretNotification = Notification.Name("SecureStorageDidChangeSecret")

    public enum NotificationUserInfoKey {
        public static let identifier = "identifier"
        public static let operation = "operation"
        public static let updatedAt = "updatedAt"
    }

    private let configuration: SecureStorageConfiguration
    private let keychain: SecureStorageKeychainItems
    private let permissionsChecker: any KeychainPermissionsChecking
    private let identifierRegistry: (any APIKeyIdentifierRegistry)?

    private var cache: [String: String] = [:]
    private var didLoadFromKeychain = false
    /// Coalesces the first Keychain read across concurrent startup callers.
    ///
    /// Actor methods are reentrant at `await` points. Without this shared task,
    /// several services can all pass the `didLoadFromKeychain` check and enter
    /// Security.framework at once while the app is launching.
    private var cacheLoadTask: Task<Void, Error>?

    public init(
        configuration: SecureStorageConfiguration = .default,
        permissionsChecker: any KeychainPermissionsChecking = DefaultKeychainPermissions(),
        identifierRegistry: (any APIKeyIdentifierRegistry)? = nil
    ) {
        self.configuration = configuration
        self.keychain = SecureStorageKeychainItems(configuration: configuration)
        self.permissionsChecker = permissionsChecker
        self.identifierRegistry = identifierRegistry
    }

    // MARK: - Public API

    public func storeSecret(_ value: String, identifier: String) async throws {
        try Self.validateIdentifier(identifier)
        try await ensureCacheLoaded()

        guard await permissionsChecker.ensureKeychainAccess(forService: configuration.service) else {
            throw SecureStorageError.permissionDenied
        }

        let previousValue = cache.updateValue(value, forKey: identifier)
        do {
            try keychain.write(cache: cache)
        } catch {
            if let previousValue {
                cache[identifier] = previousValue
            } else {
                cache.removeValue(forKey: identifier)
            }
            throw error
        }

        if let registry = identifierRegistry {
            await MainActor.run {
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    registry.removeAPIKeyIdentifier(identifier)
                } else {
                    registry.registerAPIKeyIdentifier(identifier)
                }
            }
        }

        postChangeNotification(identifier: identifier, operation: "store")
    }

    public func secret(identifier: String) async throws -> String {
        try Self.validateIdentifier(identifier)
        try await ensureCacheLoaded()

        guard let cached = cache[identifier] else {
            throw SecureStorageError.valueNotFound
        }

        return cached
    }

    public func removeSecret(identifier: String) async throws {
        try Self.validateIdentifier(identifier)
        try await ensureCacheLoaded()

        guard await permissionsChecker.ensureKeychainAccess(forService: configuration.service) else {
            throw SecureStorageError.permissionDenied
        }

        let previousValue = cache.removeValue(forKey: identifier)
        do {
            try keychain.write(cache: cache)
        } catch {
            if let previousValue {
                cache[identifier] = previousValue
            }
            throw error
        }

        if let registry = identifierRegistry {
            await MainActor.run {
                registry.removeAPIKeyIdentifier(identifier)
            }
        }

        postChangeNotification(identifier: identifier, operation: "remove")
    }

    public func knownIdentifiers() async -> [String] {
        try? await ensureCacheLoaded()
        return storedIdentifiers
    }

    public func hasSecret(identifier: String) async -> Bool {
        guard (try? Self.validateIdentifier(identifier)) != nil else { return false }
        try? await ensureCacheLoaded()
        if let cached = cache[identifier]?.trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
            return true
        }
        return false
    }

    /// Rejects empty (or whitespace-only) identifiers at every public
    /// boundary, before any cache, keychain, registry or notification effect:
    /// an empty identifier previously succeeded in memory, serialised as
    /// `=value`, and was silently dropped by the parser on the next load
    /// (issue #672).
    private static func validateIdentifier(_ identifier: String) throws {
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SecureStorageError.emptyIdentifier
        }
    }

    /// The accessibility class the stored secrets item actually carries, read
    /// back off the keychain item itself (issue #997).
    ///
    /// This is a real read of the real item's `kSecAttrAccessible` attribute
    /// with `kSecReturnData` off, not a restatement of what the write path
    /// asked for, because the two can differ — a migrated item keeps the class
    /// it was created with, which is the whole of issue #930: a `WhenUnlocked`
    /// item is unreadable during a locked-device capture and the capture
    /// silently downgrades to Apple Speech instead of saying so.
    ///
    /// Returns `nil` when there is no item to inspect. The raw attribute
    /// string never leaves this method.
    public func storedAccessibility() -> CaptureHealthAccessibility? { keychain.storedAccessibility() }

    public func preload() async {
        try? await ensureCacheLoaded()
    }

    @discardableResult
    public func preloadAndReportSuccess() async -> Bool {
        do {
            try await ensureCacheLoaded()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private Implementation

    private func ensureCacheLoaded() async throws {
        if didLoadFromKeychain { return }

        if let cacheLoadTask {
            try await cacheLoadTask.value
            return
        }

        let task = Task {
            try await loadCacheFromKeychain()
        }
        cacheLoadTask = task

        do {
            try await task.value
            cacheLoadTask = nil
        } catch {
            cacheLoadTask = nil
            throw error
        }
    }

    private func loadCacheFromKeychain() async throws {
        if didLoadFromKeychain { return }

        guard await permissionsChecker.ensureKeychainAccess(forService: configuration.service) else {
            throw SecureStorageError.permissionDenied
        }

        var compatibilityPayload = try keychain.readPayload(account: configuration.masterAccount)
        var overflowPayload = try keychain.readPayload(account: keychain.overflowAccount)

        if compatibilityPayload == nil, overflowPayload == nil {
            if try migrateLegacyServicePayloadIfNeeded() {
                await reconcileCachedIdentifiers()
                didLoadFromKeychain = true
                return
            }

            try await migrateLegacySecretsIfNeeded()
            compatibilityPayload = try keychain.readPayload(account: configuration.masterAccount)
            overflowPayload = try keychain.readPayload(account: keychain.overflowAccount)
        }

        // Mixed-version contract (issue #672): the master account holds the
        // legacy-format compatibility record every shipped parser can read,
        // and the overflow account holds the versioned payload for values the
        // legacy format cannot represent. The master account wins per key so
        // an intermediate build that rewrote it (in any format) keeps its
        // edits, while overflow-only secrets it never saw survive.
        var secrets: [String: String] = [:]
        if let overflowPayload {
            switch Self.parsePayload(overflowPayload) {
            case .secrets(let parsed):
                secrets = parsed
            case .unsupportedVersion(let marker):
                try preserveUnsupportedPayload(overflowPayload, marker: marker)
            }
        }
        if let compatibilityPayload {
            switch Self.parsePayload(compatibilityPayload) {
            case .secrets(let parsed):
                secrets.merge(parsed) { _, master in master }
            case .unsupportedVersion(let marker):
                try preserveUnsupportedPayload(compatibilityPayload, marker: marker)
            }
        }

        cache = secrets
        await reconcileCachedIdentifiers()
        didLoadFromKeychain = true
    }

    /// A payload with a newer version marker than this build understands is
    /// copied aside before anything can overwrite it, and is never parsed as
    /// legacy data (which would invent the marker as an identifier). The
    /// first backup wins; a failed backup fails the load so the record cannot
    /// be discarded.
    private func preserveUnsupportedPayload(_ payload: String, marker: String) throws {
        Self.logger.error(
            "Unsupported secure-storage payload version \(marker, privacy: .public); preserving a backup"
        )
        guard try keychain.readPayload(account: keychain.unsupportedBackupAccount) == nil else { return }
        try keychain.writePayload(payload, account: keychain.unsupportedBackupAccount)
    }

    private func reconcileCachedIdentifiers() async {
        if let registry = identifierRegistry {
            let identifiers = storedIdentifiers
            await MainActor.run {
                registry.reconcileAPIKeyIdentifiers(identifiers)
            }
        }
    }

    private var storedIdentifiers: [String] {
        cache.compactMap { identifier, value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : identifier
        }
        .sorted()
    }

    private func migrateLegacyServicePayloadIfNeeded() throws -> Bool {
        for legacyService in configuration.legacyServices
        where legacyService != configuration.service {
            guard let payload = try keychain.readLegacyServicePayload(service: legacyService) else { continue }
            guard case .secrets(let parsed) = Self.parsePayload(payload) else {
                Self.logger.error(
                    "Skipping legacy service migration: unsupported payload version"
                )
                continue
            }
            cache = parsed
            try keychain.write(cache: cache)
            return true
        }

        return false
    }

    private func migrateLegacySecretsIfNeeded() async throws {
        var trackedIdentifiers: [String] = []
        if let registry = identifierRegistry {
            trackedIdentifiers = await MainActor.run { registry.trackedAPIKeyIdentifiers }
        }

        let legacyAccounts = try keychain.legacyAccounts()
        let candidates = Set(trackedIdentifiers).union(legacyAccounts)
            .subtracting([configuration.masterAccount, keychain.overflowAccount, keychain.unsupportedBackupAccount])

        guard !candidates.isEmpty else { return }

        var migrated: [String: String] = [:]

        for identifier in candidates {
            if let value = try keychain.readLegacySecret(identifier: identifier) {
                migrated[identifier] = value
            }
        }

        guard !migrated.isEmpty else { return }

        cache = migrated
        try keychain.write(cache: cache)
        migrated.keys.forEach { keychain.deleteLegacySecret(identifier: $0) }
        cache = [:]
    }

    private func postChangeNotification(identifier: String, operation: String) {
        NotificationCenter.default.post(
            name: Self.didChangeSecretNotification,
            object: nil,
            userInfo: [
                Self.NotificationUserInfoKey.identifier: identifier,
                Self.NotificationUserInfoKey.operation: operation,
                Self.NotificationUserInfoKey.updatedAt: Date()
            ]
        )
    }
}
