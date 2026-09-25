import Foundation
import SpeakCore

/// Developer configuration for CloudKit Web Services.
///
/// The API token is created per container in CloudKit Console (Settings →
/// Tokens & Keys) by the app's developer and must be supplied by the host's
/// configuration. It is never hard-coded here, and a missing token is a
/// configuration failure, not a fallback to another backend.
public struct CloudKitWebServicesConfiguration: Equatable, Sendable {
    public enum Environment: String, CaseIterable, Sendable {
        /// Not reachable by apps from the store.
        case development
        /// The environment shipped Apple builds read and write.
        case production
    }

    public static let defaultBaseURL = URL(string: "https://api.apple-cloudkit.com")!

    public let containerIdentifier: String
    public let environment: Environment
    public let apiToken: String
    public let baseURL: URL

    /// `baseURL` must be `defaultBaseURL`, or a loopback address for a local
    /// fake server in tests; any other base throws `invalidBaseURL`.
    public init(
        containerIdentifier: String,
        environment: Environment,
        apiToken: String,
        baseURL: URL = CloudKitWebServicesConfiguration.defaultBaseURL
    ) throws {
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw CloudKitWebServicesConfigurationError.missingAPIToken
        }
        guard Self.isValidContainerIdentifier(containerIdentifier) else {
            throw CloudKitWebServicesConfigurationError.invalidContainerIdentifier(containerIdentifier)
        }
        guard Self.isAllowedBaseURL(baseURL) else {
            throw CloudKitWebServicesConfigurationError.invalidBaseURL
        }
        self.containerIdentifier = containerIdentifier
        self.environment = environment
        self.apiToken = token
        self.baseURL = baseURL
    }

    /// Configuration for one existing container family in a release train.
    public init(
        family: SyncContainerFamily,
        train: ReleaseTrain,
        environment: Environment,
        apiToken: String
    ) throws {
        try self.init(
            containerIdentifier: family.containerIdentifier(in: train),
            environment: environment,
            apiToken: apiToken
        )
    }

    /// Every request carries the developer API token and, for private data,
    /// the user's web auth token, so the base is CloudKit's own service
    /// endpoint (`defaultBaseURL`) and nothing else. The one exception is this
    /// computer's loopback address, over HTTP or HTTPS, so native transports
    /// can be exercised against a local fake server; tokens sent there never
    /// leave the machine. Credentials, queries and fragments in the base are
    /// refused everywhere.
    static func isAllowedBaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            return false
        }
        if loopbackHosts.contains(host) {
            return scheme == "http" || scheme == "https"
        }
        return scheme == "https" && host == serviceHost && (url.port == nil || url.port == 443)
            && (url.path.isEmpty || url.path == "/")
    }

    /// The host of `defaultBaseURL`, the only remote host requests may reach.
    static let serviceHost = "api.apple-cloudkit.com"

    /// This computer's loopback names, for local fake servers in tests.
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    /// Container identifiers begin with `iCloud.`, as the web service requires.
    static func isValidContainerIdentifier(_ identifier: String) -> Bool {
        let prefix = "iCloud."
        guard identifier.hasPrefix(prefix), identifier.count > prefix.count else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return identifier.allSatisfy { allowed.contains($0) }
    }
}

public enum CloudKitWebServicesConfigurationError: Error, Equatable, Sendable {
    /// The developer API token for this container is not configured.
    case missingAPIToken
    case invalidContainerIdentifier(String)
    case invalidBaseURL
}

extension CloudKitWebServicesConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIToken:
            return "iCloud sync is not configured for this build: no CloudKit API token was provided."
        case .invalidContainerIdentifier(let identifier):
            return "“\(identifier)” is not a CloudKit container identifier."
        case .invalidBaseURL:
            return "CloudKit Web Services requests go only to https://api.apple-cloudkit.com, "
                + "or to this computer's loopback address for local tests."
        }
    }
}

/// Features a user can opt into separately. Nothing syncs until a feature is
/// enabled, and enabling History uploads that device's pending entries to the
/// user's own private database — the same step an Apple device takes.
public enum CloudKitWebSyncFeature: String, Codable, CaseIterable, Sendable {
    case history
    case comparisonRounds
    /// Passphrase-encrypted API keys. Also needs its own passphrase entry.
    case apiKeys
}

/// A user's explicit sync choices. The default is no consent.
public struct CloudKitWebSyncConsent: Codable, Equatable, Sendable {
    public private(set) var enabledFeatures: Set<CloudKitWebSyncFeature>

    public static let none = CloudKitWebSyncConsent(enabledFeatures: [])

    public init(enabledFeatures: Set<CloudKitWebSyncFeature>) {
        self.enabledFeatures = enabledFeatures
    }

    public func allows(_ feature: CloudKitWebSyncFeature) -> Bool {
        enabledFeatures.contains(feature)
    }

    func require(_ feature: CloudKitWebSyncFeature) throws {
        guard allows(feature) else { throw CloudKitWebServicesError.consentRequired(feature) }
    }
}

/// What the documented CloudKit Web Services API can and cannot do for the
/// existing data. See `Docs/windows-cloudkit-sync.md` for the sources.
public enum CloudKitWebServicesCapability: String, CaseIterable, Sendable {
    case privateDatabaseAuthentication
    case customZoneChangeFeed
    case recordLookup
    case conditionalRecordWrites
    case recordDeletion
    case zoneCreation
    case callerIdentity
    case changeNotifications
    case nativeChangeTokenInterchange
    case changeTokenExpiryRecovery
    case assetTransfer
    case apiKeyEnvelopeCryptography

    public var support: CloudKitWebServicesSupport {
        Self.supportTable[self] ?? .unsupported(blocker: "Not assessed.")
    }

    private static let supportTable: [CloudKitWebServicesCapability: CloudKitWebServicesSupport] = [
        .privateDatabaseAuthentication: .requiresExternalConfiguration(
            "A developer API token for the container and an interactive Apple ID sign-in that returns a "
                + "ckWebAuthToken to the token's registered sign-in callback URL. The token rotates on every response."
        ),
        .customZoneChangeFeed: .supported(
            evidence: "POST …/private/changes/zone (custom zones only) with syncToken and moreComing"
        ),
        .recordLookup: .supported(evidence: "POST …/private/records/lookup with per-record NOT_FOUND results"),
        .conditionalRecordWrites: .supported(
            evidence: "POST …/private/records/modify: create, update with recordChangeTag, atomic false"
        ),
        .recordDeletion: .supported(evidence: "records/modify forceDelete, matching a native delete by record ID"),
        .zoneCreation: .supported(evidence: "POST …/private/zones/modify create"),
        .callerIdentity: .supported(evidence: "GET …/public/users/caller returns the container-scoped userRecordName"),
        .changeNotifications: .unsupported(
            blocker: "Existing subscriptions push through APNs. The web API's tokens/create long-poll URL has no "
                + "documented message format or delivery guarantee for these subscriptions; clients poll instead."
        ),
        .nativeChangeTokenInterchange: .unsupported(
            blocker: "Native clients archive CKServerChangeToken; the web API returns an opaque syncToken. "
                + "Each client keeps its own cursor and replays from the start on first sync."
        ),
        .changeTokenExpiryRecovery: .unsupported(
            blocker: "The documented error codes include no expired-sync-token code, so an expired cursor "
                + "is reported as a failure rather than silently reset."
        ),
        .assetTransfer: .unsupported(
            blocker: "No existing record type has an Asset field (audio stays on device), so asset upload and "
                + "download are not implemented; fields this client does not write are never overwritten."
        ),
        .apiKeyEnvelopeCryptography: .requiresExternalConfiguration(
            "A platform provider for SyncEnvelopeCryptography (CryptoKit on Apple, CNG on Windows) "
                + "and the user's passphrase. Web clients only read keys; the Apple engine remains the writer."
        )
    ]

    /// Throws `CloudKitWebServicesError.unsupported` for an unsupported capability.
    public func requireSupported() throws {
        if case .unsupported = support {
            throw CloudKitWebServicesError.unsupported(self)
        }
    }
}

public enum CloudKitWebServicesSupport: Equatable, Sendable {
    case supported(evidence: String)
    case requiresExternalConfiguration(String)
    case unsupported(blocker: String)
}
