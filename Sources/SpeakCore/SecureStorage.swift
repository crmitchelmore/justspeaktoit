import Foundation
import Security
import os

// swiftlint:disable file_length

// MARK: - Error Types

public enum SecureStorageError: LocalizedError, Equatable {
    case permissionDenied
    case valueNotFound
    case emptyIdentifier
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Keychain access was denied. Please review your Security & Privacy settings."
        case .valueNotFound:
            return "No value found for the requested identifier."
        case .emptyIdentifier:
            return "A secret identifier must not be empty."
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
///
/// `Sendable` so the existential can be stored on the `SecureStorage` actor and
/// hopped to the main actor for registry updates. Conformers are `@MainActor`
/// classes (e.g. `AppSettings`), which are implicitly Sendable.
@MainActor
public protocol APIKeyIdentifierRegistry: AnyObject, Sendable {
    func registerAPIKeyIdentifier(_ identifier: String)
    func removeAPIKeyIdentifier(_ identifier: String)
    func reconcileAPIKeyIdentifiers(_ identifiers: [String])
    var trackedAPIKeyIdentifiers: [String] { get }
}

public extension APIKeyIdentifierRegistry {
    func reconcileAPIKeyIdentifiers(_ identifiers: [String]) {
        let canonicalIdentifiers = Set(identifiers)
        trackedAPIKeyIdentifiers
            .filter { !canonicalIdentifiers.contains($0) }
            .forEach(removeAPIKeyIdentifier)
        canonicalIdentifiers
            .sorted()
            .filter { !trackedAPIKeyIdentifiers.contains($0) }
            .forEach(registerAPIKeyIdentifier)
    }
}

// MARK: - Secure Storage Configuration

public struct SecureStorageConfiguration: Sendable {
    public let service: String
    public let masterAccount: String
    /// Previous service names whose aggregate payload should be copied into the
    /// canonical service on first access. Legacy items are retained so older app
    /// versions can still roll back safely.
    public let legacyServices: [String]
    /// Optional access group for keychain sharing between apps (e.g., "$(AppIdentifierPrefix)com.speak.shared")
    public let accessGroup: String?
    /// Whether to sync via iCloud Keychain (requires accessGroup)
    public let synchronizable: Bool

    public init(
        service: String = "com.github.speakapp.credentials",
        masterAccount: String = "speak-app-secrets",
        legacyServices: [String] = [],
        accessGroup: String? = nil,
        synchronizable: Bool = false
    ) {
        self.service = service
        self.masterAccount = masterAccount
        self.legacyServices = legacyServices
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
    }

    public static let `default` = SecureStorageConfiguration()
}

// MARK: - Secure Storage Actor

/// Cross-platform secure storage for API keys and secrets.
/// Uses Keychain Services on both macOS and iOS.
public actor SecureStorage {
    // swiftlint:disable:previous type_body_length
    private static let logger = SpeakLogger.logger(category: "SecureStorage")

    public static let didChangeSecretNotification = Notification.Name("SecureStorageDidChangeSecret")

    public enum NotificationUserInfoKey {
        public static let identifier = "identifier"
        public static let operation = "operation"
        public static let updatedAt = "updatedAt"
    }
    
    private let configuration: SecureStorageConfiguration
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
            try writeCacheToKeychain()
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
            try writeCacheToKeychain()
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

        var compatibilityPayload = try readPayload(account: configuration.masterAccount)
        var overflowPayload = try readPayload(account: overflowAccount)

        if compatibilityPayload == nil, overflowPayload == nil {
            if try migrateLegacyServicePayloadIfNeeded() {
                await reconcileCachedIdentifiers()
                didLoadFromKeychain = true
                return
            }

            try await migrateLegacySecretsIfNeeded()
            compatibilityPayload = try readPayload(account: configuration.masterAccount)
            overflowPayload = try readPayload(account: overflowAccount)
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
        guard try readPayload(account: unsupportedBackupAccount) == nil else { return }
        try writePayload(payload, account: unsupportedBackupAccount)
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
            var query = baseQuery(account: configuration.masterAccount)
            query[kSecAttrService as String] = legacyService
            query[kSecReturnData as String] = true

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)

            if status == errSecItemNotFound {
                continue
            }

            guard status == errSecSuccess,
                  let data = item as? Data,
                  let payload = String(data: data, encoding: .utf8)
            else {
                throw SecureStorageError.unexpectedStatus(status)
            }

            guard case .secrets(let parsed) = Self.parsePayload(payload) else {
                Self.logger.error(
                    "Skipping legacy service migration: unsupported payload version"
                )
                continue
            }
            cache = parsed
            try writeCacheToKeychain()
            return true
        }

        return false
    }

    /// The overflow account holding the versioned payload for values the
    /// legacy compatibility record cannot represent (issue #672).
    private var overflowAccount: String { configuration.masterAccount + ".v2" }

    /// Where a payload with an unknown newer version marker is preserved
    /// before this build writes anything (issue #672).
    private var unsupportedBackupAccount: String { configuration.masterAccount + ".unsupported-backup" }

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

    /// Reads one account's payload, or `nil` when the item does not exist.
    private func readPayload(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let payload = String(data: data, encoding: .utf8)
        else {
            throw SecureStorageError.unexpectedStatus(status)
        }
        return payload
    }

    private func migrateLegacySecretsIfNeeded() async throws {
        var trackedIdentifiers: [String] = []
        if let registry = identifierRegistry {
            trackedIdentifiers = await MainActor.run { registry.trackedAPIKeyIdentifiers }
        }
        
        let legacyAccounts = try fetchLegacyAccounts()
        let candidates = Set(trackedIdentifiers).union(legacyAccounts)
            .subtracting([configuration.masterAccount, overflowAccount, unsupportedBackupAccount])

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

    /// Persists the cache under the documented mixed-version contract
    /// (issue #672): the master account carries the legacy-format
    /// compatibility record for every representable entry, the overflow
    /// account carries the versioned payload for the rest. If the second
    /// write fails, the first is rolled back so the two accounts never
    /// disagree about a half-applied save.
    private func writeCacheToKeychain() throws {
        let compatibility = Self.serializeLegacyCompatibilityRecord(cache: cache)
        let overflow = Self.serializeOverflowPayload(cache: cache)

        let previousCompatibility = try readPayload(account: configuration.masterAccount)
        try writePayload(compatibility, account: configuration.masterAccount)
        do {
            try writePayload(overflow, account: overflowAccount)
        } catch {
            try? writePayload(previousCompatibility ?? "", account: configuration.masterAccount)
            throw error
        }
    }

    /// Writes one account's payload; an empty payload deletes the item.
    private func writePayload(_ payload: String, account: String) throws {
        let query = baseQuery(account: account)

        if payload.isEmpty {
            let deleteStatus = SecItemDelete(query as CFDictionary)
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

        // IMPORTANT: Only set these attributes when we have the entitlement
        // kSecAttrSynchronizable requires keychain-access-groups entitlement
        // kSecAttrAccessible with certain values may also require it on some configs
        if configuration.accessGroup != nil && configuration.synchronizable {
            attributesToUpdate[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            attributesToUpdate[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }

        let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrLabel as String] = account

            // Only set these for entitled apps
            if configuration.accessGroup != nil && configuration.synchronizable {
                addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                addQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
            }

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                Self.logger.debug("ERROR: SecItemAdd failed with \(addStatus, privacy: .private)")
                throw SecureStorageError.unexpectedStatus(addStatus)
            }
        } else if status != errSecSuccess {
            Self.logger.debug("ERROR: SecItemUpdate failed with \(status, privacy: .private)")
            throw SecureStorageError.unexpectedStatus(status)
        }
    }

    // MARK: - Payload Format
    //
    // Mixed-version contract (issue #672). Two keychain items per store:
    //
    // | Account                     | Format          | Contents                        |
    // |-----------------------------|-----------------|---------------------------------|
    // | masterAccount               | legacy `k=v;`   | every legacy-representable entry|
    // | masterAccount.v2            | versioned v2    | entries legacy cannot represent |
    // | masterAccount.unsupported-… | opaque          | backup of a newer-version item  |
    //
    // The master account stays in the legacy interchange format so *every*
    // shipped parser — including pre-versioning builds after a rollback —
    // reads correct plaintext values and never sees percent-encoded secrets
    // or a version marker as an identifier. Values the legacy format cannot
    // carry (containing `;`, or edge whitespace the legacy parser trims)
    // live only in the versioned overflow item, which legacy builds never
    // read. On load the two are merged with the master account winning per
    // key. A payload carrying a *newer* version marker than this build
    // understands is preserved to a backup account and never parsed as
    // legacy or overwritten silently.
    //
    // Version migration table — extend this (and the fixtures in
    // SecureStoragePayloadFormatTests) whenever a version is added; never
    // change an existing format in place:
    //
    // | Marker  | Body                                   | Introduced |
    // |---------|----------------------------------------|------------|
    // | (none)  | raw `key=value;key=value`              | v1 (legacy)|
    // | `v2:;`  | percent-encoded `key=value;` pairs     | #631       |

    /// The payload version this build writes for the overflow item.
    static let currentPayloadVersion = 2

    /// Prefix identifying the current payload format. The trailing `;` makes the marker
    /// unforgeable by the legacy serializer: a legacy payload always begins with an
    /// identifier followed by `=`, so it can never start with `v2:;`. A legacy identifier
    /// that merely starts with `v2:` therefore still parses as legacy data.
    static let payloadVersionPrefix = "v2:;"

    /// Characters that may appear unescaped in an encoded payload key or value.
    /// The structural characters `;` and `=`, and the escape character `%`, are excluded.
    private static let payloadComponentAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ";=%&+")
        return allowed
    }()

    /// Explicit format-detection result: secrets, or a version this build
    /// does not understand (never interpreted as legacy data).
    enum ParsedPayload: Equatable {
        case secrets([String: String])
        case unsupportedVersion(String)
    }

    /// The `v<digits>:;` marker version, or `nil` for legacy payloads. The
    /// mandatory `;` directly after the colon keeps legacy identifiers that
    /// merely start with `v2:` parsing as legacy data.
    static func versionMarker(of payload: String) -> Int? {
        guard payload.first == "v", let colon = payload.firstIndex(of: ":") else { return nil }
        let digits = payload[payload.index(after: payload.startIndex)..<colon]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        let afterColon = payload.index(after: colon)
        guard afterColon < payload.endIndex, payload[afterColon] == ";" else { return nil }
        return Int(digits)
    }

    static func parsePayload(_ payload: String) -> ParsedPayload {
        guard let version = versionMarker(of: payload) else {
            return .secrets(parseLegacyPayload(payload))
        }
        guard version == currentPayloadVersion else {
            return .unsupportedVersion("v\(version)")
        }
        return .secrets(parseVersionedBody(payload))
    }

    /// Convenience for callers that treat an unsupported version as empty.
    /// The load path uses `parsePayload` so it can preserve a backup first.
    static func parse(payload: String) -> [String: String] {
        guard case .secrets(let secrets) = parsePayload(payload) else { return [:] }
        return secrets
    }

    private static func parseVersionedBody(_ payload: String) -> [String: String] {
        payload
            .dropFirst(payloadVersionPrefix.count)
            .split(separator: ";")
            .reduce(into: [String: String]()) { partialResult, item in
                let components = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let keyComponent = components.first else { return }
                let key = String(keyComponent).removingPercentEncoding ?? String(keyComponent)
                guard !key.isEmpty else { return }
                let rawValue = components.count > 1 ? String(components[1]) : ""
                partialResult[key] = rawValue.removingPercentEncoding ?? rawValue
            }
    }

    private static func parseLegacyPayload(_ payload: String) -> [String: String] {
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

    /// Serializes to the current versioned format. An empty cache serializes to an empty
    /// string (not a bare version prefix) so `writePayload` still deletes the item.
    static func serialize(cache: [String: String]) -> String {
        guard !cache.isEmpty else { return "" }

        let body = cache
            .sorted { $0.key < $1.key }
            .map { "\(encodePayloadComponent($0.key))=\(encodePayloadComponent($0.value))" }
            .joined(separator: ";")
        return payloadVersionPrefix + body
    }

    /// Whether the legacy `key=value;` format can carry this entry verbatim:
    /// the identifier must survive the `;`/first-`=` splits and the legacy
    /// parser's pair trimming unchanged, and the value must survive the `;`
    /// split and trailing trim. Anything else belongs to the overflow item —
    /// a legacy reader must never receive a percent-encoded stand-in.
    static func isLegacyRepresentable(identifier: String, value: String) -> Bool {
        guard !identifier.isEmpty,
              !identifier.contains(";"), !identifier.contains("="),
              identifier.trimmingCharacters(in: .whitespacesAndNewlines) == identifier
        else { return false }
        guard !value.contains(";"),
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value
        else { return false }
        return true
    }

    /// The legacy-format compatibility record for the master account.
    static func serializeLegacyCompatibilityRecord(cache: [String: String]) -> String {
        cache
            .filter { isLegacyRepresentable(identifier: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }

    /// The versioned payload for entries the legacy format cannot represent.
    static func serializeOverflowPayload(cache: [String: String]) -> String {
        serialize(cache: cache.filter { !isLegacyRepresentable(identifier: $0.key, value: $0.value) })
    }

    private static func encodePayloadComponent(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: payloadComponentAllowedCharacters) ?? component
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
