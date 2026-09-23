import Foundation

/// Where the rotating CloudKit web auth token is kept between launches.
///
/// CloudKit returns a new token with each response and the previous one stops
/// working, so every save must complete before the next request. Keep it as a
/// credential (Windows Credential Manager, Keychain), never in plain settings
/// or logs. Calls should return promptly: the client runs them in order,
/// one at a time.
public protocol CloudKitWebAuthTokenStore: Sendable {
    func loadWebAuthToken() async throws -> String?
    func saveWebAuthToken(_ token: String) async throws
    func clearWebAuthToken() async throws
}

/// One sign-in session of a `CloudKitWebServicesClient`.
///
/// Every request of a logical operation carries the session the operation
/// began in. After the user signs out, signs in again or iCloud rejects the
/// session, those requests fail with `CloudKitWebServicesError.sessionChanged`
/// instead of being sent under the new session. Token rotation within a
/// session does not change it.
public struct CloudKitWebSession: Equatable, Sendable {
    let generation: UInt64
}

public struct CloudKitWebRetryPolicy: Equatable, Sendable {
    /// Attempts per call, including the first.
    public var maximumAttempts: Int
    public var initialBackoff: Duration
    public var maximumBackoff: Duration
    /// The longest server `retryAfter` waited inside one call. A longer wait
    /// fails the call with the server error, so the next sync pass retries.
    public var maximumServerDelay: Duration

    public static let standard = CloudKitWebRetryPolicy(
        maximumAttempts: 4,
        initialBackoff: .seconds(1),
        maximumBackoff: .seconds(30),
        maximumServerDelay: .seconds(60)
    )

    public init(
        maximumAttempts: Int,
        initialBackoff: Duration,
        maximumBackoff: Duration,
        maximumServerDelay: Duration
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.initialBackoff = initialBackoff
        self.maximumBackoff = maximumBackoff
        self.maximumServerDelay = maximumServerDelay
    }

    /// Exponential backoff after the given 1-based attempt, capped.
    func backoff(afterAttempt attempt: Int) -> Duration {
        let exponent = min(max(attempt - 1, 0), 16)
        return min(initialBackoff * (1 << exponent), maximumBackoff)
    }
}

enum CloudKitWebServicesDatabase: String, Sendable {
    case privateDatabase = "private"
    case publicDatabase = "public"
}

public enum CloudKitWebServicesLimits {
    /// Maximum operations in one request, from the reference's Data Size Limits.
    public static let maximumOperationsPerRequest = 200
    /// Maximum records in one response, from the same table.
    public static let maximumRecordsPerResponse = 200
}

/// One CloudKit Web Services operation, before tokens are attached.
struct CloudKitWebCall: Sendable {
    let method: String
    let database: CloudKitWebServicesDatabase
    let operation: String
    let body: Data?

    static func post(
        _ database: CloudKitWebServicesDatabase,
        _ operation: String,
        body: some Encodable
    ) throws -> CloudKitWebCall {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(body)
        } catch {
            throw SyncError.encodingFailed
        }
        return CloudKitWebCall(method: "POST", database: database, operation: operation, body: data)
    }

    static func get(_ database: CloudKitWebServicesDatabase, _ operation: String) -> CloudKitWebCall {
        CloudKitWebCall(method: "GET", database: database, operation: operation, body: nil)
    }
}
