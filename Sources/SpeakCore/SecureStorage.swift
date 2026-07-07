import Foundation
import Security
import os

// MARK: - Error Types

public enum SecureStorageError: LocalizedError {
    case permissionDenied
    case valueNotFound
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
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
}

// MARK: - Protocol for Permissions Checking

/// Protocol for checking permissions before keychain access.
/// Platform-specific implementations handle the actual permission checks.
public protocol KeychainPermissionsChecking: Sendable {
    func ensureKeychainAccess(forService service: String) async -> Bool
}

/// Default implementation that always grants access (for platforms without special requirements)
public actor DefaultKeychainPermissions: KeychainPermissionsChecking {
    public init() {}
    
    public func ensureKeychainAccess(forService service: String) async -> Bool {
        true
    }
}

// MARK: - Protocol for Settings Integration

/// Protocol for registering known API key identifiers with app settings.
@MainActor
public protocol APIKeyIdentifierRegistry: AnyObject {
    func registerAPIKeyIdentifier(_ identifier: String)
    func removeAPIKeyIdentifier(_ identifier: String)
    var trackedAPIKeyIdentifiers: [String] { get }
}

// MARK: - Secure Storage Configuration

public struct SecureStorageConfiguration: Sendable {
    public let service: String
    public let masterAccount: String
    /// Optional access group for keychain sharing between apps (e.g., "$(AppIdentifierPrefix)com.speak.shared")
    public let accessGroup: String?
    /// Whether to sync via iCloud Keychain (requires accessGroup)
    public let synchronizable: Bool

    public init(
        service: String = "com.github.speakapp.credentials",
        masterAccount: String = "speak-app-secrets",
        accessGroup: String? = nil,
        synchronizable: Bool = false
    ) {
        self.service = service
        self.masterAccount = masterAccount
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
    }

    public static let `default` = SecureStorageConfiguration()
}

// MARK: - Secure Storage Actor

/// Cross-platform secure storage for API keys and secrets.
/// Uses Keychain Services on both macOS and iOS.
public actor SecureStorage {
    private static let logger = Logger(subsystem: "com.justspeaktoit", category: "SecureStorage")
    
    private let configuration: SecureStorageConfiguration
    private let permissionsChecker: any KeychainPermissionsChecking
    private let identifierRegistry: (any APIKeyIdentifierRegistry)?
    
    private var cache: [String: String] = [:]
    private var didLoadFromKeychain = false

    public init(
        configuration: SecureStorageConfiguration = .default,
        permissionsChecker: any KeychainPermissionsChecking = DefaultKeychainPermissions(),
        identifierRegistry: (any APIKeyIdentifierRegistry)? = nil
    ) {
        self.configuration = configuration
        self.permissionsChecker = permissionsChecker
        self.identifierRegistry = identifierRegistry
    }

    // MARK: - Public API

    public func storeSecret(_ value: String, identifier: String) async throws {
        try await ensureCacheLoaded()

        guard await permissionsChecker.ensureKeychainAccess(forService: configuration.service) else {
            throw SecureStorageError.permissionDenied
        }

        cache[identifier] = value
        try writeCacheToKeychain()

        if let registry = identifierRegistry {
            await MainActor.run {
                registry.registerAPIKeyIdentifier(identifier)
            }
        }
    }

    public func secret(identifier: String) async throws -> String {
        try await ensureCacheLoaded()

        guard let cached = cache[identifier] else {
            throw SecureStorageError.valueNotFound
        }

        return cached
    }

    public func removeSecret(identifier: String) async throws {
        try await ensureCacheLoaded()

        cache.removeValue(forKey: identifier)

        guard await permissionsChecker.ensureKeychainAccess(forService: configuration.service) else {
            throw SecureStorageError.permissionDenied
        }

        try writeCacheToKeychain()

        if let registry = identifierRegistry {
            await MainActor.run {
                registry.removeAPIKeyIdentifier(identifier)
            }
        }
    }

    public func knownIdentifiers() async -> [String] {
        try? await ensureCacheLoaded()
        return cache.keys.sorted()
    }

    public func hasSecret(identifier: String) async -> Bool {
        try? await ensureCacheLoaded()
        if let cached = cache[identifier]?.trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
            return true
        }
        return false
    }

    public func preload() async {
        try? await ensureCacheLoaded()
    }

    // MARK: - Private Implementation

    private func ensureCacheLoaded() async throws {
        if didLoadFromKeychain { return }

        guard await permissionsChecker.ensureKeychainAccess(forService: configuration.service) else {
            throw SecureStorageError.permissionDenied
        }

        var query = baseQuery()
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            try await migrateLegacySecretsIfNeeded()
            status = SecItemCopyMatching(query as CFDictionary, &item)
        }

        if status == errSecItemNotFound {
            cache = [:]
            didLoadFromKeychain = true
            return
        }

        guard status == errSecSuccess, let data = item as? Data,
              let payload = String(data: data, encoding: .utf8)
        else {
            throw SecureStorageError.unexpectedStatus(status)
        }

        cache = parse(payload: payload)
        didLoadFromKeychain = true

        if let registry = identifierRegistry {
            let identifiers = Array(cache.keys)
            await MainActor.run {
                identifiers.forEach { registry.registerAPIKeyIdentifier($0) }
            }
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
            kSecAttrAccount as String: configuration.masterAccount,
        ]
        
        if let accessGroup = configuration.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        if configuration.synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        
        return query
    }

    private func migrateLegacySecretsIfNeeded() async throws {
        var trackedIdentifiers: [String] = []
        if let registry = identifierRegistry {
            trackedIdentifiers = await MainActor.run { registry.trackedAPIKeyIdentifiers }
        }
        
        let legacyAccounts = try fetchLegacyAccounts()
        let candidates = Set(trackedIdentifiers).union(legacyAccounts)
            .subtracting([configuration.masterAccount])

        guard !candidates.isEmpty else { return }

        var migrated: [String: String] = [:]

        for identifier in candidates {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: configuration.service,
                kSecAttrAccount as String: identifier,
                kSecReturnData as String: true,
            ]
            
            if let accessGroup = configuration.accessGroup {
                query[kSecAttrAccessGroup as String] = accessGroup
            }

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)

            if status == errSecItemNotFound {
                continue
            }

            guard status == errSecSuccess, let data = item as? Data,
                  let value = String(data: data, encoding: .utf8)
            else {
                throw SecureStorageError.unexpectedStatus(status)
            }

            migrated[identifier] = value
        }

        guard !migrated.isEmpty else { return }

        cache = migrated
        try writeCacheToKeychain()
        migrated.keys.forEach { deleteLegacySecret(identifier: $0) }
        cache = [:]
        didLoadFromKeychain = false
    }

    private func fetchLegacyAccounts() throws -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        
        if let accessGroup = configuration.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return []
        }

        guard status == errSecSuccess else {
            throw SecureStorageError.unexpectedStatus(status)
        }

        guard let array = result as? [[String: Any]] else { return [] }
        return array.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func deleteLegacySecret(identifier: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
            kSecAttrAccount as String: identifier,
        ]
        
        if let accessGroup = configuration.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        SecItemDelete(query as CFDictionary)
    }

    private func writeCacheToKeychain() throws {
        let payload = serialize(cache: cache)

        let query = baseQuery()
        
        // DEBUG: Log the query to verify no synchronizable
        Self.logger.debug("writeCacheToKeychain - baseQuery keys: \(query.keys, privacy: .private)")
        Self.logger.debug("configuration.synchronizable: \(self.configuration.synchronizable, privacy: .private)")
        Self.logger.debug("configuration.accessGroup: \(self.configuration.accessGroup ?? "nil", privacy: .private)")

        if payload.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(payload.utf8)
        var attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: configuration.masterAccount,
        ]
        
        // IMPORTANT: Only set these attributes when we have the entitlement
        // kSecAttrSynchronizable requires keychain-access-groups entitlement
        // kSecAttrAccessible with certain values may also require it on some configs
        if configuration.accessGroup != nil && configuration.synchronizable {
            attributesToUpdate[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            attributesToUpdate[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        
        Self.logger.debug("attributesToUpdate keys: \(attributesToUpdate.keys, privacy: .private)")

        let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        Self.logger.debug("SecItemUpdate status: \(status, privacy: .private)")
        
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrLabel as String] = configuration.masterAccount
            
            // Only set these for entitled apps
            if configuration.accessGroup != nil && configuration.synchronizable {
                addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                addQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
            }
            
            Self.logger.debug("SecItemAdd query keys: \(addQuery.keys, privacy: .private)")
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            Self.logger.debug("SecItemAdd status: \(addStatus, privacy: .private)")
            
            guard addStatus == errSecSuccess else {
                Self.logger.debug("ERROR: SecItemAdd failed with \(addStatus, privacy: .private)")
                throw SecureStorageError.unexpectedStatus(addStatus)
            }
        } else if status != errSecSuccess {
            Self.logger.debug("ERROR: SecItemUpdate failed with \(status, privacy: .private)")
            throw SecureStorageError.unexpectedStatus(status)
        }
    }

    private func parse(payload: String) -> [String: String] {
        payload
            .split(separator: ";")
            .reduce(into: [String: String]()) { partialResult, item in
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let components = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let keyComponent = components.first else { return }
                let key = String(keyComponent)
                let value = components.count > 1 ? String(components[1]) : ""
                partialResult[key] = value
            }
    }

    private func serialize(cache: [String: String]) -> String {
        cache
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }
}
