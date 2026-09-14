import Foundation

/// One `URLProtocol` stub for the whole test suite, replacing the per-file
/// copies that each re-implemented "return this canned response, record the
/// request" (issue #1124).
///
/// Deliberately does not import XCTest, so the iOS test bundle can compile it
/// through Tuist's source glob without linking the test framework. A handler
/// that is not set fails the request with `StubURLProtocol.Error.noHandler`
/// rather than calling `XCTFail`; assert on that in the test if it matters.
///
/// State is static, matching what the copies it replaces did, and is guarded by
/// a lock so recording stays safe when a client issues concurrent requests.
/// Call `reset()` in `tearDown` (or `setUp`) so one test cannot leak a handler
/// into the next.
public final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// What the stub should do with one request.
    public enum Outcome: Sendable {
        /// Send the response and body, then finish loading. Takes `URLResponse`
        /// rather than `HTTPURLResponse` because some tests deliberately return
        /// a non-HTTP response to exercise that error path.
        case respond(URLResponse, Data)
        /// Send the response and body but never finish, so the caller sees an
        /// in-flight request. Used by the cancellation tests.
        case respondWithoutFinishing(URLResponse, Data)
        /// Fail the request with this error.
        case fail(Swift.Error)
    }

    public enum Error: Swift.Error {
        /// `handler` was nil when a request arrived.
        case noHandler
    }

    public typealias Handler = @Sendable (URLRequest) async throws -> Outcome

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: Handler?
    nonisolated(unsafe) private static var _recordedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var _onStartLoading: (@Sendable () -> Void)?
    nonisolated(unsafe) private static var _onStopLoading: (@Sendable () -> Void)?

    /// Produces the outcome for each request. Set this before exercising the
    /// code under test.
    public static var handler: Handler? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    /// Every request the stub has seen, oldest first, exactly as sent. A body
    /// supplied as a stream stays a stream here — use `body(of:)` to read it.
    public static var recordedRequests: [URLRequest] {
        lock.withLock { _recordedRequests }
    }

    /// The most recent request, or nil if none has arrived.
    public static var lastRequest: URLRequest? {
        lock.withLock { _recordedRequests.last }
    }

    /// Called after a request has been recorded and its outcome delivered.
    public static var onStartLoading: (@Sendable () -> Void)? {
        get { lock.withLock { _onStartLoading } }
        set { lock.withLock { _onStartLoading = newValue } }
    }

    /// Called when the loading system cancels a request.
    public static var onStopLoading: (@Sendable () -> Void)? {
        get { lock.withLock { _onStopLoading } }
        set { lock.withLock { _onStopLoading = newValue } }
    }

    /// Convenience for the shape almost every replaced copy used: return a
    /// response and a body, then finish loading. Equivalent to setting
    /// `handler` and wrapping the result in `.respond`.
    public static func respond(
        with handler: @escaping @Sendable (URLRequest) async throws -> (URLResponse, Data)
    ) {
        self.handler = { request in
            let (response, data) = try await handler(request)
            return .respond(response, data)
        }
    }

    /// Clears the recorded requests but leaves the handler and callbacks in
    /// place, for tests that install a handler and then build their session.
    public static func resetRecordedRequests() {
        lock.withLock { _recordedRequests = [] }
    }

    /// Clears the handler, the recorded requests and both callbacks.
    public static func reset() {
        lock.withLock {
            _handler = nil
            _recordedRequests = []
            _onStartLoading = nil
            _onStopLoading = nil
        }
    }

    /// A session that routes every request through this stub.
    public static func makeSession(
        configuration: URLSessionConfiguration = .ephemeral
    ) -> URLSession {
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// `URLSession` strips `httpBody` from the request handed to a protocol and
    /// replaces it with a stream, so multipart bodies have to be read back.
    public static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private let stopLock = NSRecursiveLock()
    private var stopped = false
    private var loadTask: Task<Void, Never>?

    override public static func canInit(with request: URLRequest) -> Bool { true }

    override public static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        // The request is recorded and handed to the handler exactly as sent.
        // It is deliberately NOT drained into `httpBody`: tests that prove a
        // large upload streams rather than buffering assert `httpBody == nil`,
        // and draining here would consume the stream before the client reads
        // it. Call `body(of:)` when a test wants the bytes.
        let sent = request
        let handler: Handler? = Self.lock.withLock {
            Self._recordedRequests.append(sent)
            return Self._handler
        }

        guard let handler else {
            deliver(.fail(Error.noHandler), for: sent)
            return
        }

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await handler(sent)
                try Task.checkCancellation()
                self.deliver(outcome, for: sent)
            } catch {
                self.deliver(.fail(error), for: sent)
            }
        }
    }

    override public func stopLoading() {
        // Cancelling matters: the deadline tests assert that tearing down an
        // in-flight request actually cancels the work behind it.
        stopLock.withLock {
            stopped = true
            loadTask?.cancel()
        }
        Self.onStopLoading?()
    }

    private func deliver(_ outcome: Outcome, for request: URLRequest) {
        stopLock.withLock {
            guard !stopped else { return }
            switch outcome {
            case let .respond(response, data):
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case let .respondWithoutFinishing(response, data):
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
            case let .fail(error):
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        Self.onStartLoading?()
    }
}

// MARK: - Convenience builders

extension StubURLProtocol.Outcome {
    /// A 200 JSON response carrying `body`.
    public static func ok(
        _ body: Data,
        url: URL = URL(string: "https://stub.invalid")!,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) -> Self {
        .respond(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!,
            body
        )
    }

    /// A response with `statusCode` carrying `body`.
    public static func status(
        _ statusCode: Int,
        _ body: Data = Data(),
        url: URL = URL(string: "https://stub.invalid")!,
        headers: [String: String]? = nil
    ) -> Self {
        .respond(
            HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!,
            body
        )
    }
}
