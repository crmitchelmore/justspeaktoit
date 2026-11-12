import Foundation
import Security

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
    public enum Accessibility: Sendable {
        /// Preserve the existing platform and synchronizable-store defaults.
        case platformDefault
        /// Available after the first unlock, including while locked; remains backup eligible.
        case afterFirstUnlock
    }

    public let accessibility: Accessibility

    var keychainAccessibility: CFString? {
        if accessibility == .afterFirstUnlock || (accessGroup != nil && synchronizable) {
            return kSecAttrAccessibleAfterFirstUnlock
        }
        return nil
    }

    public let service: String
    // Public SpeakCore API and the persisted Keychain account; renaming it is a breaking change.
    public let masterAccount: String // swiftlint:disable:this inclusive_language
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
        masterAccount: String = "speak-app-secrets", // swiftlint:disable:this inclusive_language
        legacyServices: [String] = [],
        accessGroup: String? = nil,
        synchronizable: Bool = false
    ) {
        self.init(service: service, masterAccount: masterAccount, legacyServices: legacyServices,
                  accessGroup: accessGroup, synchronizable: synchronizable,
                  accessibility: .platformDefault, releaseTrain: .current)
    }

    public init(
        service: String = "com.github.speakapp.credentials",
        masterAccount: String = "speak-app-secrets", // swiftlint:disable:this inclusive_language
        legacyServices: [String] = [],
        accessGroup: String? = nil,
        synchronizable: Bool = false,
        releaseTrain: ReleaseTrain
    ) {
        self.init(service: service, masterAccount: masterAccount, legacyServices: legacyServices,
                  accessGroup: accessGroup, synchronizable: synchronizable,
                  accessibility: .platformDefault, releaseTrain: releaseTrain)
    }

    public init(
        service: String = "com.github.speakapp.credentials",
        masterAccount: String = "speak-app-secrets", // swiftlint:disable:this inclusive_language
        legacyServices: [String] = [],
        accessGroup: String? = nil,
        synchronizable: Bool = false,
        accessibility: Accessibility
    ) {
        self.init(service: service, masterAccount: masterAccount, legacyServices: legacyServices,
                  accessGroup: accessGroup, synchronizable: synchronizable,
                  accessibility: accessibility, releaseTrain: .current)
    }

    /// Designated initialiser. `accessibility` and `releaseTrain` are both
    /// explicit here so neither policy can be dropped by a forwarding overload.
    public init(
        service: String = "com.github.speakapp.credentials",
        masterAccount: String = "speak-app-secrets", // swiftlint:disable:this inclusive_language
        legacyServices: [String] = [],
        accessGroup: String? = nil,
        synchronizable: Bool = false,
        accessibility: Accessibility,
        releaseTrain: ReleaseTrain
    ) {
        self.service = releaseTrain.namespace(service)
        self.masterAccount = masterAccount
        self.legacyServices = legacyServices.map { releaseTrain.namespace($0) }
        self.accessGroup = accessGroup.map { releaseTrain.namespace($0) }
        self.synchronizable = synchronizable
        self.accessibility = accessibility
    }

    public static let `default` = SecureStorageConfiguration()
}
