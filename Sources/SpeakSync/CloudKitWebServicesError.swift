import Foundation

/// A `serverErrorCode` from CloudKit Web Services. The documented codes are
/// named; any other code is preserved as received.
public struct CloudKitWebServerErrorCode: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let accessDenied = Self(rawValue: "ACCESS_DENIED")
    public static let atomicError = Self(rawValue: "ATOMIC_ERROR")
    public static let authenticationFailed = Self(rawValue: "AUTHENTICATION_FAILED")
    public static let authenticationRequired = Self(rawValue: "AUTHENTICATION_REQUIRED")
    public static let badRequest = Self(rawValue: "BAD_REQUEST")
    /// The `recordChangeTag` is stale: another client changed the record.
    public static let conflict = Self(rawValue: "CONFLICT")
    public static let exists = Self(rawValue: "EXISTS")
    public static let internalError = Self(rawValue: "INTERNAL_ERROR")
    public static let notFound = Self(rawValue: "NOT_FOUND")
    public static let quotaExceeded = Self(rawValue: "QUOTA_EXCEEDED")
    public static let throttled = Self(rawValue: "THROTTLED")
    public static let tryAgainLater = Self(rawValue: "TRY_AGAIN_LATER")
    public static let validatingReferenceError = Self(rawValue: "VALIDATING_REFERENCE_ERROR")
    public static let zoneNotFound = Self(rawValue: "ZONE_NOT_FOUND")
}

/// A request-level or per-record error dictionary.
public struct CloudKitWebServerError: Error, Equatable, Sendable, Decodable {
    public let code: CloudKitWebServerErrorCode
    public let reason: String?
    public let recordName: String?
    /// Seconds to wait before retrying. The reference states an operation
    /// without this key cannot be retried.
    public let retryAfter: Double?
    /// Present with `AUTHENTICATION_REQUIRED`: where the user signs in.
    public let redirectURL: URL?
    public let uuid: String?

    private enum CodingKeys: String, CodingKey {
        case serverErrorCode
        case reason
        case recordName
        case retryAfter
        case redirectURL
        case uuid
    }

    init(
        code: CloudKitWebServerErrorCode,
        reason: String? = nil,
        recordName: String? = nil,
        retryAfter: Double? = nil,
        redirectURL: URL? = nil,
        uuid: String? = nil
    ) {
        self.code = code
        self.reason = reason
        self.recordName = recordName
        self.retryAfter = retryAfter
        self.redirectURL = redirectURL
        self.uuid = uuid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = CloudKitWebServerErrorCode(rawValue: try container.decode(String.self, forKey: .serverErrorCode))
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        recordName = try container.decodeIfPresent(String.self, forKey: .recordName)
        retryAfter = try? container.decodeIfPresent(Double.self, forKey: .retryAfter)
        redirectURL = (try? container.decodeIfPresent(String.self, forKey: .redirectURL)).flatMap(URL.init(string:))
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
    }
}

extension CloudKitWebServerError: LocalizedError {
    public var errorDescription: String? {
        if let reason, !reason.isEmpty {
            return "iCloud rejected the request (\(code.rawValue)): \(reason)"
        }
        return "iCloud rejected the request (\(code.rawValue))."
    }
}

public enum CloudKitWebServicesError: Error, Equatable, Sendable {
    /// The request needs an interactive Apple ID sign-in. Open `redirectURL` in
    /// the user's browser; the API token's sign-in callback receives the new
    /// `ckWebAuthToken`. This is an external gate, never retried automatically.
    case authenticationRequired(redirectURL: URL?)
    /// CloudKit rejected the web auth token or the API token. The saved token
    /// has been discarded.
    case authenticationFailed(reason: String?)
    case server(CloudKitWebServerError)
    case invalidResponse(String)
    case transport(CloudKitWebServicesTransportError)
    /// The rotated web auth token could not be saved, so this device may need
    /// to sign in again after relaunch.
    case tokenPersistenceFailed
    case unsupported(CloudKitWebServicesCapability)
    case consentRequired(CloudKitWebSyncFeature)
    /// A stored cursor was not written by this transport.
    case invalidChangeToken
    /// The user signed out or in, or iCloud rejected the session, after this
    /// operation began. It was not sent under the new session.
    case sessionChanged
}

extension CloudKitWebServicesError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "Sign in with your Apple ID to sync with iCloud."
        case .authenticationFailed:
            return "iCloud rejected this sign-in. Sign in with your Apple ID again."
        case .server(let error):
            return error.errorDescription
        case .invalidResponse(let detail):
            return "iCloud returned an unexpected response: \(detail)"
        case .transport(let error):
            return error == .timedOut ? "iCloud did not respond in time." : "Could not reach iCloud."
        case .tokenPersistenceFailed:
            return "The iCloud sign-in could not be saved on this device."
        case .unsupported(let capability):
            return "\(capability.rawValue) is not available through CloudKit Web Services."
        case .consentRequired(let feature):
            return "Turn on \(feature.rawValue) sync before syncing it with iCloud."
        case .invalidChangeToken:
            return "The saved iCloud sync position does not belong to this client."
        case .sessionChanged:
            return "The iCloud sign-in changed while syncing. Sync again."
        }
    }
}
