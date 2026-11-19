import CryptoKit
import Foundation

/// HTTP implementation of ``PaidAccessClienting``.
///
/// Follows the same shape as the other SpeakCore transports — injected
/// `URLSession`, endpoint constant, typed errors, credentials only ever in
/// headers — with two additions the paid path needs: an explicit request
/// timeout, and a correlation identifier on every request so a user-visible
/// failure can be traced in the Worker's logs without asking for any content.
public struct PaidAccessHTTPClient: PaidAccessClienting {
    /// Production by default. An internal app resolves its own build flag and
    /// injects a staging endpoint explicitly; SwiftPM does not inherit app flags.
    public static var defaultBaseURL: URL {
        URL(string: "https://api.justspeaktoit.com")!
    }

    private let transport: PaidAccessTransport

    public init(
        baseURL: URL = PaidAccessHTTPClient.defaultBaseURL,
        session: URLSession = .shared,
        timeout: TimeInterval = 60
    ) {
        self.transport = PaidAccessTransport(baseURL: baseURL, session: session, timeout: timeout)
    }

    // MARK: - Authentication

    public func signInWithApple(
        identityToken: String,
        rawNonce: String,
        deviceLabel: String?
    ) async throws -> PaidAccessSession {
        var request = try self.transport.makeRequest(path: "v1/auth/apple", method: "POST", session: nil)
        var body: [String: Any] = ["identity_token": identityToken, "nonce": rawNonce]
        if let deviceLabel {
            body["device_label"] = deviceLabel
        }
        try self.transport.encodeBody(body, into: &request)
        return try await self.transport.send(request, as: SessionResponse.self).session
    }

    public func refresh(session: PaidAccessSession) async throws -> PaidAccessSession {
        var request = try self.transport.makeRequest(path: "v1/auth/refresh", method: "POST", session: nil)
        try self.transport.encodeBody(["refresh_token": session.refreshToken], into: &request)
        return try await self.transport.send(request, as: SessionResponse.self).session
    }

    public func signOut(session: PaidAccessSession) async {
        guard var request = try? self.transport.makeRequest(
            path: "v1/auth/sign-out",
            method: "POST",
            session: session
        ) else { return }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try? await self.transport.sendExpectingData(request)
    }

    // MARK: - Entitlement

    /// One round trip returns both halves of the state, so the app never has to
    /// stitch an entitlement to a policy fetched by a second call that may fail.
    public func entitlement(session: PaidAccessSession) async throws -> PaidAccessState {
        let request = try self.transport.makeRequest(path: "v1/entitlement", method: "GET", session: session)
        return try await self.transport.send(request, as: EntitlementResponse.self).state
    }

    // MARK: - Billing

    public func createCheckoutURL(session: PaidAccessSession) async throws -> URL {
        var request = try self.transport.makeRequest(
            path: "v1/billing/stripe/checkout",
            method: "POST",
            session: session
        )
        try self.transport.encodeBody(["channel": "direct"], into: &request)
        let response = try await self.transport.send(request, as: CheckoutResponse.self)
        guard let url = URL(string: response.checkoutURL) else {
            throw PaidAccessError.invalidResponse
        }
        return url
    }

    public func createBillingPortalURL(session: PaidAccessSession) async throws -> URL {
        var request = try self.transport.makeRequest(
            path: "v1/billing/stripe/portal",
            method: "POST",
            session: session
        )
        try self.transport.encodeBody(["channel": "direct"], into: &request)
        let response = try await self.transport.send(request, as: PortalResponse.self)
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
        var request = try self.transport.makeRequest(
            path: "v1/billing/storekit/sync",
            method: "POST",
            session: session
        )
        var body: [String: Any] = ["signed_transaction": signedTransaction]
        if let signedRenewalInfo {
            body["signed_renewal_info"] = signedRenewalInfo
        }
        try self.transport.encodeBody(body, into: &request)
        return try await self.transport.send(request, as: StoreKitSyncResponse.self).entitlement
    }

    // MARK: - Paid routing

    public func transcribe(
        session: PaidAccessSession,
        audio: Data,
        contentType: String,
        language: String?,
        idempotencyKey: String
    ) async throws -> String {
        var request = try self.transport.makeRequest(
            path: "v1/paid/transcribe/batch",
            method: "POST",
            session: session,
            query: language.map { [URLQueryItem(name: "language", value: $0)] } ?? []
        )
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("1", forHTTPHeaderField: "X-Paid-Settlement-Contract")
        request.httpBody = audio
        return try await self.transport.send(request, as: TextResponse.self).text
    }

    public func postProcess(
        session: PaidAccessSession,
        text: String,
        systemPrompt: String?,
        temperature: Double,
        idempotencyKey: String
    ) async throws -> String {
        var request = try self.transport.makeRequest(
            path: "v1/paid/post-process",
            method: "POST",
            session: session
        )
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("1", forHTTPHeaderField: "X-Paid-Settlement-Contract")
        var body: [String: Any] = [
            "operation": PaidOperation.postProcessing.rawValue,
            "text": text,
            "temperature": temperature
        ]
        if let systemPrompt {
            body["system_prompt"] = systemPrompt
        }
        try self.transport.encodeBody(body, into: &request)
        return try await self.transport.send(request, as: TextResponse.self).text
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
        var request = try self.transport.makeRequest(
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
