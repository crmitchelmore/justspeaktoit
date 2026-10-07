import Foundation

/// A CloudKit Web Services client for one container and environment.
///
/// Requests use the developer API token and the user's web auth token.
/// "Each token is intended for a single round trip": every response carries a
/// replacement and the previous token stops working. The replacement is read
/// from `X-Apple-CloudKit-Web-Auth-Token`, falling back to
/// `X-Apple-CloudKit-Session` — the headers Apple's CloudKit JS reads; the
/// reference itself does not name one.
///
/// Ordering: one FIFO gate admits a single request, session change or piece of
/// account-bound local work at a time. The first read of the stored token,
/// every rotation, sign-in, sign-out and rejected session happen only while
/// holding it, so a slow read can never land after a later change. Backoff
/// waits happen outside the gate, and each attempt re-checks the operation's
/// `CloudKitWebSession` under the gate, so a retry never crosses a sign-out or
/// sign-in. Transient failures are retried with bounded backoff;
/// authentication failures are never retried.
public actor CloudKitWebServicesClient {
    public static let defaultResponseLimit = 16 * 1024 * 1024
    static let webAuthTokenHeader = "X-Apple-CloudKit-Web-Auth-Token"
    static let sessionHeader = "X-Apple-CloudKit-Session"

    public nonisolated let configuration: CloudKitWebServicesConfiguration
    let responseLimit: Int
    private let transport: any CloudKitWebServicesHTTPTransport
    private let tokenStore: any CloudKitWebAuthTokenStore
    private let retryPolicy: CloudKitWebRetryPolicy
    private let sleep: @Sendable (Duration) async throws -> Void
    private var cachedToken: String?
    private var hasLoadedToken = false
    private var sessionGeneration: UInt64 = 0
    private var requestInFlight = false
    private var waiters: [Waiter] = []

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private enum Outcome {
        case completed(CloudKitWebServicesHTTPResponse)
        case retry(after: Duration, failure: CloudKitWebServicesError)
    }

    public init(
        configuration: CloudKitWebServicesConfiguration,
        tokenStore: any CloudKitWebAuthTokenStore,
        transport: any CloudKitWebServicesHTTPTransport = URLSessionCloudKitWebServicesTransport(),
        retryPolicy: CloudKitWebRetryPolicy = .standard,
        responseLimit: Int = CloudKitWebServicesClient.defaultResponseLimit,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.responseLimit = responseLimit
        self.sleep = sleep
    }

    // MARK: - Sign-in session

    /// The current sign-in session. Pass it to every request of one logical
    /// operation, so they all run in that session or fail together.
    public func session() -> CloudKitWebSession {
        CloudKitWebSession(generation: sessionGeneration)
    }

    /// Completes an interactive sign-in from the API token's sign-in callback,
    /// `https://<callback>/?ckWebAuthToken=<token>`.
    public func completeSignIn(callbackURL: URL) async throws {
        guard let token = Self.webAuthToken(fromCallback: callbackURL) else {
            throw CloudKitWebServicesError.authenticationRequired(redirectURL: nil)
        }
        try await storeWebAuthToken(token)
    }

    /// Starts a session from a web auth token delivered another way (for
    /// example `postMessage`). Operations begun before it cannot continue.
    public func storeWebAuthToken(_ token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CloudKitWebServicesError.authenticationRequired(redirectURL: nil) }
        try await acquire()
        defer { release() }
        beginSession(token: trimmed)
        try await persist(trimmed)
    }

    /// Ends the session on this device. It waits for an in-flight request, so
    /// that request's rotated token cannot restore the session afterwards, and
    /// operations begun before it fail instead of continuing signed out. If the
    /// stored token cannot be cleared the error is thrown, but this process
    /// stays signed out.
    public func signOut() async throws {
        try await acquire()
        defer { release() }
        beginSession(token: nil)
        do {
            try await tokenStore.clearWebAuthToken()
        } catch {
            throw CloudKitWebServicesError.tokenPersistenceFailed
        }
    }

    public func hasWebAuthToken() async throws -> Bool {
        try await acquire()
        defer { release() }
        return try await loadedToken() != nil
    }

    static func webAuthToken(fromCallback url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        guard let token = items?.first(where: { $0.name == "ckWebAuthToken" })?.value, !token.isEmpty else {
            return nil
        }
        return token
    }

    // MARK: - Requests

    /// Sends one call in `session` — by default the session current as the
    /// call begins — and decodes the documented JSON response.
    func perform<Response: Decodable>(
        _ call: CloudKitWebCall,
        in session: CloudKitWebSession? = nil,
        as type: Response.Type
    ) async throws -> Response {
        let response = try await send(call, in: session ?? self.session())
        do {
            return try JSONDecoder().decode(Response.self, from: response.body)
        } catch {
            throw CloudKitWebServicesError.invalidResponse("The response body was not the documented JSON.")
        }
    }

    private func send(
        _ call: CloudKitWebCall,
        in session: CloudKitWebSession
    ) async throws -> CloudKitWebServicesHTTPResponse {
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            switch try await exchangeHoldingGate(call, in: session, attempt: attempt) {
            case .completed(let response):
                return response
            case .retry(let delay, let failure):
                guard attempt < retryPolicy.maximumAttempts else { throw failure }
                try await sleep(delay)
            }
        }
    }

    private func exchangeHoldingGate(
        _ call: CloudKitWebCall,
        in session: CloudKitWebSession,
        attempt: Int
    ) async throws -> Outcome {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        // Checked under the gate, after any queued sign-in, sign-out or
        // rejection has run: an operation's payload is only ever sent in the
        // session it began in.
        guard session.generation == sessionGeneration else {
            throw CloudKitWebServicesError.sessionChanged
        }
        let request = try makeRequest(call, token: try await loadedToken())
        let response: CloudKitWebServicesHTTPResponse
        do {
            response = try await transport.send(request, responseLimit: responseLimit)
        } catch let error as CloudKitWebServicesTransportError {
            return try transportOutcome(error, attempt: attempt)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let kind = String(describing: type(of: error))
            throw CloudKitWebServicesError.transport(.connectionFailed(retryable: false, description: kind))
        }
        try await rotateToken(from: response)
        return try await responseOutcome(response, attempt: attempt)
    }

    private func transportOutcome(_ error: CloudKitWebServicesTransportError, attempt: Int) throws -> Outcome {
        switch error {
        case .timedOut, .connectionFailed(retryable: true, _):
            return .retry(after: retryPolicy.backoff(afterAttempt: attempt), failure: .transport(error))
        default:
            throw CloudKitWebServicesError.transport(error)
        }
    }

    private func responseOutcome(_ response: CloudKitWebServicesHTTPResponse, attempt: Int) async throws -> Outcome {
        if (200..<300).contains(response.statusCode) {
            return .completed(response)
        }
        let serverError = try? JSONDecoder().decode(CloudKitWebServerError.self, from: response.body)
        if response.statusCode == 421 || serverError?.code == .authenticationRequired {
            await rejectSession()
            throw CloudKitWebServicesError.authenticationRequired(redirectURL: serverError?.redirectURL)
        }
        if response.statusCode == 401 || serverError?.code == .authenticationFailed {
            await rejectSession()
            throw CloudKitWebServicesError.authenticationFailed(reason: serverError?.reason)
        }
        if let serverError {
            guard let delay = retryDelay(for: serverError, attempt: attempt) else {
                throw CloudKitWebServicesError.server(serverError)
            }
            return .retry(after: delay, failure: .server(serverError))
        }
        let status = CloudKitWebServicesError.invalidResponse("HTTP \(response.statusCode)")
        guard [502, 503, 504].contains(response.statusCode) else { throw status }
        return .retry(after: retryPolicy.backoff(afterAttempt: attempt), failure: status)
    }

    private func retryDelay(for error: CloudKitWebServerError, attempt: Int) -> Duration? {
        if let seconds = error.retryAfter, seconds.isFinite, seconds >= 0 {
            let delay = Duration.seconds(seconds)
            return delay <= retryPolicy.maximumServerDelay ? delay : nil
        }
        guard error.code == .throttled || error.code == .tryAgainLater else { return nil }
        return retryPolicy.backoff(afterAttempt: attempt)
    }

    private func makeRequest(_ call: CloudKitWebCall, token: String?) throws -> CloudKitWebServicesHTTPRequest {
        var url = configuration.baseURL
        let path = ["database", "1", configuration.containerIdentifier, configuration.environment.rawValue,
                    call.database.rawValue] + call.operation.split(separator: "/").map(String.init)
        for component in path {
            url.appendPathComponent(component)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CloudKitWebServicesConfigurationError.invalidBaseURL
        }
        var query = "ckAPIToken=" + Self.percentEncode(configuration.apiToken)
        if let token {
            query += "&ckWebAuthToken=" + Self.percentEncode(token)
        }
        components.percentEncodedQuery = query
        guard let requestURL = components.url else { throw CloudKitWebServicesConfigurationError.invalidBaseURL }
        var headers = ["Accept": "application/json"]
        if call.body != nil {
            headers["Content-Type"] = "text/plain"
        }
        return CloudKitWebServicesHTTPRequest(method: call.method, url: requestURL, headers: headers, body: call.body)
    }

    /// Percent-encodes everything outside RFC 3986's unreserved set, which covers
    /// the reference's rule for `+`, `/` and `=` in a web auth token.
    static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? ""
    }

    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}

// MARK: - Session state (only while holding the gate)

extension CloudKitWebServicesClient {
    /// Replaces the session; operations begun in the previous one now fail.
    private func beginSession(token: String?) {
        sessionGeneration &+= 1
        cachedToken = token
        hasLoadedToken = true
    }

    /// The session's token. The store is read once, under the gate, so no
    /// later sign-in, sign-out or rotation can be overwritten by that read.
    private func loadedToken() async throws -> String? {
        guard !hasLoadedToken else { return cachedToken }
        let stored: String?
        do {
            stored = try await tokenStore.loadWebAuthToken()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudKitWebServicesError.tokenPersistenceFailed
        }
        cachedToken = stored
        hasLoadedToken = true
        return stored
    }

    /// Adopts a rotated token within the same session and saves it before the
    /// next request can use it.
    private func rotateToken(from response: CloudKitWebServicesHTTPResponse) async throws {
        let rotated = response.header(Self.webAuthTokenHeader) ?? response.header(Self.sessionHeader)
        guard let rotated, !rotated.isEmpty, rotated != cachedToken else { return }
        try await persist(rotated)
    }

    private func persist(_ token: String) async throws {
        cachedToken = token
        hasLoadedToken = true
        do {
            try await tokenStore.saveWebAuthToken(token)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudKitWebServicesError.tokenPersistenceFailed
        }
    }

    /// A rejected session is never reused. A failed clear only leaves a token
    /// the server will reject again, so it does not mask the sign-in error.
    private func rejectSession() async {
        beginSession(token: nil)
        try? await tokenStore.clearWebAuthToken()
    }
}

// MARK: - Account-bound local work

extension CloudKitWebServicesClient {
    /// Runs local work that belongs to `session`'s iCloud user — reading or
    /// rebinding the account, clearing or saving a cursor, applying changes or
    /// acknowledgements — only while that session is current. The work holds
    /// the gate that requests and session changes take, so no sign-in,
    /// sign-out or rejected session takes effect while it runs, and none that
    /// already has is ever followed by it: it fails with `sessionChanged`, or
    /// `CancellationError` once its task is cancelled, and does not run. The
    /// work must not send requests through this client. The `isolation`
    /// parameter, not the client, isolates it.
    func whileCurrent<Value>(
        _ session: CloudKitWebSession,
        isolation: isolated (any Actor)? = #isolation,
        _ work: () async throws -> Value
    ) async throws -> Value {
        try await admit(session)
        do {
            let value = try await work()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    /// Takes the gate for `session`'s work; the caller releases it.
    private func admit(_ session: CloudKitWebSession) async throws {
        try await acquire()
        do {
            try Task.checkCancellation()
            guard session.generation == sessionGeneration else { throw CloudKitWebServicesError.sessionChanged }
        } catch {
            release()
            throw error
        }
    }
}

// MARK: - One request or session change at a time

extension CloudKitWebServicesClient {
    /// Operations queued behind the one in flight (tests observe ordering with it).
    var waitingRequestCount: Int { waiters.count }

    /// Waits for the gate in FIFO order. A waiter cancelled before its turn is
    /// removed and never owns the gate; once granted, the owner's `defer`
    /// releases it on every path, including cancellation.
    private func acquire() async throws {
        try Task.checkCancellation()
        guard requestInFlight else {
            requestInFlight = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: id, continuation: continuation))
                if Task.isCancelled {
                    cancelWaiter(id)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Hands the gate to the next waiter, or opens it.
    private func release() {
        if waiters.isEmpty {
            requestInFlight = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
