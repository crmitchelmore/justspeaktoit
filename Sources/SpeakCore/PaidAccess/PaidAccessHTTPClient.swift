// swiftlint:disable file_length
import CryptoKit
import Foundation

/// HTTP implementation of ``PaidAccessClienting``.
///
/// Follows the same shape as the other SpeakCore transports — injected
/// `URLSession`, endpoint constant, typed errors, credentials only ever in
/// headers — with two additions the paid path needs: an explicit request
/// timeout, and a correlation identifier on every request so a user-visible
/// failure can be traced in the Worker's logs without asking for any content.
public struct PaidAccessHTTPClient: PaidAccessClienting { // swiftlint:disable:this type_body_length
    /// Default production endpoint.
    public static let defaultBaseURL = URL(string: "https://api.justspeaktoit.com")!

    private let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        baseURL: URL = PaidAccessHTTPClient.defaultBaseURL,
        session: URLSession = .shared,
        timeout: TimeInterval = 60
    ) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    // MARK: - Request plumbing

    private func makeRequest(
        path: String,
        method: String,
        session sessionToken: PaidAccessSession?,
        query: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: self.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw PaidAccessError.invalidResponse
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw PaidAccessError.invalidResponse
        }

        var request = URLRequest(url: url, timeoutInterval: self.timeout)
        request.httpMethod = method
        request.setValue(Self.newCorrelationID(), forHTTPHeaderField: "X-Correlation-ID")
        if let sessionToken {
            request.setValue("Bearer \(sessionToken.accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// URL-safe, matching the Worker's accepted correlation-id shape.
    static func newCorrelationID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func send<Response: Decodable>(
        _ request: URLRequest,
        as type: Response.Type
    ) async throws -> Response {
        let data = try await self.sendExpectingData(request)
        do {
            return try JSONDecoder.paidAccess.decode(Response.self, from: data)
        } catch {
            throw PaidAccessError.invalidResponse
        }
    }

    private func sendExpectingData(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw PaidAccessError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PaidAccessError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(forStatus: http.statusCode, body: data)
        }
        return data
    }

    /// Maps the Worker's error vocabulary onto ``PaidAccessError``.
    ///
    /// Response bodies are parsed for the machine-readable `code` only; the
    /// human message is not echoed because upstream messages can contain
    /// request content.
    static func error(forStatus statusCode: Int, body: Data) -> PaidAccessError {
        let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error.code
        switch code {
        case "entitlement_required": return .entitlementRequired
        case "quota_exceeded": return .quotaExceeded
        case "too_many_sessions": return .tooManySessions
        case "paid_routing_disabled": return .paidRoutingDisabled
        case "unauthorized": return .notSignedIn
        case "already_processed": return .alreadyProcessed
        case "forbidden":
            return .billingChannelUnavailable(
                "This build cannot use that payment method."
            )
        default:
            return statusCode == 401 ? .notSignedIn : .serviceUnavailable(statusCode: statusCode)
        }
    }

    private struct ErrorPayload: Decodable {
        let code: String
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorPayload
    }

    private func encodeBody(_ value: [String: Any], into request: inout URLRequest) throws {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: value)
        } catch {
            throw PaidAccessError.invalidResponse
        }
    }

    // MARK: - Authentication

    public func signInWithApple(
        identityToken: String,
        rawNonce: String,
        deviceLabel: String?
    ) async throws -> PaidAccessSession {
        var request = try self.makeRequest(path: "v1/auth/apple", method: "POST", session: nil)
        var body: [String: Any] = ["identity_token": identityToken, "nonce": rawNonce]
        if let deviceLabel {
            body["device_label"] = deviceLabel
        }
        try self.encodeBody(body, into: &request)
        return try await self.send(request, as: SessionResponse.self).session
    }

    public func refresh(session: PaidAccessSession) async throws -> PaidAccessSession {
        var request = try self.makeRequest(path: "v1/auth/refresh", method: "POST", session: nil)
        try self.encodeBody(["refresh_token": session.refreshToken], into: &request)
        return try await self.send(request, as: SessionResponse.self).session
    }

    public func signOut(session: PaidAccessSession) async {
        guard var request = try? self.makeRequest(
            path: "v1/auth/sign-out",
            method: "POST",
            session: session
        ) else { return }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try? await self.sendExpectingData(request)
    }

    // MARK: - Entitlement

    /// One round trip returns both halves of the state, so the app never has to
    /// stitch an entitlement to a policy fetched by a second call that may fail.
    public func entitlement(session: PaidAccessSession) async throws -> PaidAccessState {
        let request = try self.makeRequest(path: "v1/entitlement", method: "GET", session: session)
        return try await self.send(request, as: EntitlementResponse.self).state
    }

    // MARK: - Billing

    public func createCheckoutURL(session: PaidAccessSession) async throws -> URL {
        var request = try self.makeRequest(
            path: "v1/billing/stripe/checkout",
            method: "POST",
            session: session
        )
        try self.encodeBody(["channel": "direct"], into: &request)
        let response = try await self.send(request, as: CheckoutResponse.self)
        guard let url = URL(string: response.checkoutURL) else {
            throw PaidAccessError.invalidResponse
        }
        return url
    }

    public func createBillingPortalURL(session: PaidAccessSession) async throws -> URL {
        var request = try self.makeRequest(
            path: "v1/billing/stripe/portal",
            method: "POST",
            session: session
        )
        try self.encodeBody(["channel": "direct"], into: &request)
        let response = try await self.send(request, as: PortalResponse.self)
        guard let url = URL(string: response.portalURL) else {
            throw PaidAccessError.invalidResponse
        }
        return url
    }

    public func syncStoreKitTransaction(
        session: PaidAccessSession,
        signedTransaction: String,
        signedRenewalInfo: String?
    ) async throws -> PaidEntitlement {
        var request = try self.makeRequest(
            path: "v1/billing/storekit/sync",
            method: "POST",
            session: session
        )
        var body: [String: Any] = ["signed_transaction": signedTransaction]
        if let signedRenewalInfo {
            body["signed_renewal_info"] = signedRenewalInfo
        }
        try self.encodeBody(body, into: &request)
        return try await self.send(request, as: StoreKitSyncResponse.self).entitlement
    }

    // MARK: - Paid routing

    public func transcribe(
        session: PaidAccessSession,
        audio: Data,
        contentType: String,
        language: String?,
        idempotencyKey: String
    ) async throws -> String {
        var request = try self.makeRequest(
            path: "v1/paid/transcribe/batch",
            method: "POST",
            session: session,
            query: language.map { [URLQueryItem(name: "language", value: $0)] } ?? []
        )
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = audio
        return try await self.send(request, as: TextResponse.self).text
    }

    public func postProcess(
        session: PaidAccessSession,
        text: String,
        systemPrompt: String?,
        temperature: Double,
        idempotencyKey: String
    ) async throws -> String {
        var request = try self.makeRequest(
            path: "v1/paid/post-process",
            method: "POST",
            session: session
        )
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        var body: [String: Any] = [
            "operation": PaidOperation.postProcessing.rawValue,
            "text": text,
            "temperature": temperature
        ]
        if let systemPrompt {
            body["system_prompt"] = systemPrompt
        }
        try self.encodeBody(body, into: &request)
        return try await self.send(request, as: TextResponse.self).text
    }

    public func liveTranscriptionRequest(
        session: PaidAccessSession,
        language: String?,
        sampleRate: Int
    ) throws -> URLRequest {
        var query = [URLQueryItem(name: "sample_rate", value: String(sampleRate))]
        if let language {
            query.append(URLQueryItem(name: "language", value: language))
        }
        var request = try self.makeRequest(
            path: "v1/paid/transcribe/live",
            method: "GET",
            session: session,
            query: query
        )
        // `URLSessionWebSocketTask` requires a ws/wss URL; the base URL is https.
        guard
            let url = request.url,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw PaidAccessError.invalidResponse
        }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: break
        }
        guard let socketURL = components.url else {
            throw PaidAccessError.invalidResponse
        }
        request.url = socketURL
        // The socket connects to our Worker, not to a vendor, so only the
        // user's own session token is attached. The timeout applies to
        // connection setup, not to the established socket.
        return request
    }

    /// The idempotency key for one *logical attempt* at a paid request.
    ///
    /// The key identifies an attempt, not a piece of content. Hashing only the
    /// content looks appealing — a retry naturally presents the same key — but
    /// it makes the two cases indistinguishable, and the server cannot tell a
    /// retry of one dictation from a second, deliberate dictation of the same
    /// words. Saying "delete the file" twice in a day is ordinary use, and it
    /// would have been refused as a duplicate.
    ///
    /// So the caller supplies an `attemptID` that is stable for as long as the
    /// attempt is, and `usage_ledger(user_id, idempotency_key)` still stops a
    /// retry of *that* attempt being billed twice. Content stays in the hash as
    /// well: an attempt is identified by what was asked and when it was asked.
    ///
    /// - Parameters:
    ///   - operation: Keeps the key spaces of the paid operations apart.
    ///   - attemptID: Identity of this attempt. Reuse it to retry the same
    ///     request; generate a fresh one for a genuinely new request. Callers
    ///     with a natural per-request identity — a recording's own id, a history
    ///     item — should pass that; otherwise a fresh `UUID().uuidString`.
    ///   - parameters: Everything else that changes the result — language,
    ///     prompt, temperature.
    ///   - payload: The request body: the recorded audio, or the transcript.
    public static func idempotencyKey(
        operation: PaidOperation,
        attemptID: String,
        parameters: [String] = [],
        payload: Data
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(operation.rawValue.utf8))
        // Length-prefixed like the parameters, so an attempt id cannot be
        // confused with the parameter that follows it.
        hasher.update(data: Data("\(attemptID.utf8.count):\(attemptID)".utf8))
        for parameter in parameters {
            // Length-prefixed, so ["a", "bc"] and ["ab", "c"] cannot collide.
            hasher.update(data: Data("\(parameter.utf8.count):\(parameter)".utf8))
        }
        hasher.update(data: payload)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Wire types

private struct SessionResponse: Decodable {
    let accessToken: String
    let accessTokenExpiresAt: Double
    let refreshToken: String
    let refreshTokenExpiresAt: Double
    let userID: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accessTokenExpiresAt = "access_token_expires_at"
        case refreshToken = "refresh_token"
        case refreshTokenExpiresAt = "refresh_token_expires_at"
        case userID = "user_id"
    }

    var session: PaidAccessSession {
        PaidAccessSession(
            accessToken: self.accessToken,
            accessTokenExpiresAt: Date(timeIntervalSince1970: self.accessTokenExpiresAt),
            refreshToken: self.refreshToken,
            refreshTokenExpiresAt: Date(timeIntervalSince1970: self.refreshTokenExpiresAt),
            userID: self.userID
        )
    }
}

struct UsagePayload: Decodable {
    let period: String
    let audioSecondsUsed: Int
    let audioSecondsLimit: Int
    let tokensUsed: Int
    let tokensLimit: Int
    let activeSessions: Int
    let maxConcurrentSessions: Int

    enum CodingKeys: String, CodingKey {
        case period
        case audioSecondsUsed = "audio_seconds_used"
        case audioSecondsLimit = "audio_seconds_limit"
        case tokensUsed = "tokens_used"
        case tokensLimit = "tokens_limit"
        case activeSessions = "active_sessions"
        case maxConcurrentSessions = "max_concurrent_sessions"
    }

    var snapshot: PaidUsageSnapshot {
        PaidUsageSnapshot(
            period: self.period,
            audioSecondsUsed: self.audioSecondsUsed,
            audioSecondsLimit: self.audioSecondsLimit,
            tokensUsed: self.tokensUsed,
            tokensLimit: self.tokensLimit,
            activeSessions: self.activeSessions,
            maxConcurrentSessions: self.maxConcurrentSessions
        )
    }
}

struct RoutePayload: Decodable {
    let operation: String
    let provider: String
    let model: String
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case operation
        case provider
        case model
        case displayName = "display_name"
    }

    var route: PaidRoute? {
        guard let operation = PaidOperation(rawValue: self.operation) else { return nil }
        return PaidRoute(
            operation: operation,
            provider: self.provider,
            model: self.model,
            displayName: self.displayName
        )
    }
}

struct PolicyPayload: Decodable {
    let version: String
    let routes: [RoutePayload]

    var policy: PaidRoutingPolicy {
        // Unknown operations are dropped rather than guessed at, so a newer
        // server cannot make an older client route work it does not understand.
        PaidRoutingPolicy(version: self.version, routes: self.routes.compactMap(\.route))
    }
}

/// Internal rather than private so the tests can cover the one guarantee
/// that matters here: an entitlement and the policy it was issued with are
/// decoded from a single payload, and therefore committed together.
struct EntitlementResponse: Decodable {
    let status: String
    let planID: String
    let source: String
    let currentPeriodEnd: Double?
    let cancelAtPeriodEnd: Bool
    let paidRoutingAvailable: Bool
    let usage: UsagePayload?
    let policy: PolicyPayload?

    enum CodingKeys: String, CodingKey {
        case status
        case planID = "plan_id"
        case source
        case currentPeriodEnd = "current_period_end"
        case cancelAtPeriodEnd = "cancel_at_period_end"
        case paidRoutingAvailable = "paid_routing_available"
        case usage
        case policy
    }

    var entitlement: PaidEntitlement {
        PaidEntitlement(
            // An unrecognised status is treated as no entitlement rather than
            // being optimistically accepted.
            status: PaidEntitlementStatus(rawValue: self.status) ?? .none,
            planID: self.planID,
            provider: PaidBillingProvider(rawValue: self.source) ?? .manual,
            currentPeriodEnd: self.currentPeriodEnd.map { Date(timeIntervalSince1970: $0) },
            cancelAtPeriodEnd: self.cancelAtPeriodEnd,
            paidRoutingAvailable: self.paidRoutingAvailable,
            usage: self.usage?.snapshot
        )
    }

    /// A response without a policy yields ``PaidRoutingPolicy/unknown`` rather
    /// than an error: the entitlement is still worth publishing, and a router
    /// with no routes falls the request back to the user's own configuration.
    var state: PaidAccessState {
        PaidAccessState(
            entitlement: self.entitlement,
            policy: self.policy?.policy ?? .unknown
        )
    }
}

private struct StoreKitSyncResponse: Decodable {
    let status: String
    let active: Bool
    let currentPeriodEnd: Double?

    enum CodingKeys: String, CodingKey {
        case status
        case active
        case currentPeriodEnd = "current_period_end"
    }

    var entitlement: PaidEntitlement {
        PaidEntitlement(
            status: PaidEntitlementStatus(rawValue: self.status) ?? .none,
            planID: "paid",
            provider: .storeKit,
            currentPeriodEnd: self.currentPeriodEnd.map { Date(timeIntervalSince1970: $0) },
            cancelAtPeriodEnd: false,
            paidRoutingAvailable: self.active,
            usage: nil
        )
    }
}

private struct CheckoutResponse: Decodable {
    let checkoutURL: String

    enum CodingKeys: String, CodingKey {
        case checkoutURL = "checkout_url"
    }
}

private struct PortalResponse: Decodable {
    let portalURL: String

    enum CodingKeys: String, CodingKey {
        case portalURL = "portal_url"
    }
}

private struct TextResponse: Decodable {
    let text: String
    let model: String
    let provider: String
}
