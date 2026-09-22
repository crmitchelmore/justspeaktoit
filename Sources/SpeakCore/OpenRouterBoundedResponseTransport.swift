import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One bounded HTTP read shared by OpenRouter's dedicated transcription endpoint and its
/// audio-model discovery.
///
/// `URLSession.bytes(for:)` does not exist in swift-corelibs FoundationNetworking, so the
/// body is collected from data-delegate chunks there. Apple retains the caller’s
/// session and its existing connection pool. A declared `Content-Length` above
/// the limit is refused before any byte is read, the running total is capped at the limit,
/// a wall-clock deadline bounds the whole exchange, and redirects and HTTP caching are
/// refused. Cancelling the calling task cancels the underlying URLSession task at once;
/// every call resolves exactly once.
enum OpenRouterBoundedResponseTransport {
    enum Engine: Sendable { case platformDefault, delegate }

    struct Response: Sendable {
        let http: HTTPURLResponse
        let body: Data
    }

    enum Failure: Error, Equatable {
        case invalidResponse
        case responseTooLarge
        case timedOut
    }

    /// Inspects the headers before the body is read. Whatever it throws becomes the
    /// outcome, so a rejected status or content type never downloads a provider body.
    typealias HeaderPolicy = @Sendable (HTTPURLResponse) throws -> Void

    static func perform(
        _ request: URLRequest,
        session: URLSession,
        limit: Int,
        deadline: Duration,
        engine: Engine = .platformDefault,
        accept: @escaping HeaderPolicy = { _ in }
    ) async throws -> Response {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Response.self) { group in
            group.addTask {
                #if canImport(Darwin)
                if case .platformDefault = engine {
                    return try await receiveApple(request, session: session, limit: limit, accept: accept)
                }
                #endif
                return try await receive(request, session: session, limit: limit, accept: accept)
            }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw Failure.invalidResponse }
            return response
        }
    }

    #if canImport(Darwin)
    // Preserve the caller's connection pool, warm-up and session configuration on
    // Apple. FoundationNetworking lacks this API, so its bounded delegate engine
    // remains below. The provider contract and limits are shared by both engines.
    private static func receiveApple(
        _ request: URLRequest, session: URLSession, limit: Int, accept: @escaping HeaderPolicy
    ) async throws -> Response {
        let (bytes, response) = try await session.bytes(for: request, delegate: OpenRouterBoundedResponsePolicy())
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        try accept(http)
        guard http.expectedContentLength <= Int64(limit) else { throw Failure.responseTooLarge }
        return try await withTaskCancellationHandler {
            var body = Data()
            if http.expectedContentLength > 0 { body.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < limit else { throw Failure.responseTooLarge }
                body.append(byte)
            }
            try Task.checkCancellation()
            return Response(http: http, body: body)
        } onCancel: {
            bytes.task.cancel()
        }
    }
    #endif

    private static func receive(
        _ request: URLRequest, session: URLSession, limit: Int, accept: @escaping HeaderPolicy
    ) async throws -> Response {
        try Task.checkCancellation()
        let collector = OpenRouterBoundedResponseCollector(limit: limit, accept: accept)
        // A dedicated session keeps the caller's configuration, including injected protocol
        // classes, while owning the delegate, so per-request state never outlives the call.
        let owned = URLSession(configuration: session.configuration, delegate: collector, delegateQueue: nil)
        defer { owned.finishTasksAndInvalidate() }
        let task = owned.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.start(task, continuation: continuation)
            }
        } onCancel: {
            collector.cancel(task)
        }
    }
}

/// Collects one response under a lock. The continuation is taken exactly once, by whichever
/// of header rejection, byte-limit breach, completion or cancellation arrives first.
private final class OpenRouterBoundedResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Outcome = Result<OpenRouterBoundedResponseTransport.Response, Error>
    typealias Continuation = CheckedContinuation<OpenRouterBoundedResponseTransport.Response, Error>

    private let lock = NSLock()
    private let limit: Int
    private let accept: OpenRouterBoundedResponseTransport.HeaderPolicy
    private var continuation: Continuation?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var failure: Error?
    private var isCancelled = false

    init(limit: Int, accept: @escaping OpenRouterBoundedResponseTransport.HeaderPolicy) {
        self.limit = limit
        self.accept = accept
    }

    func start(_ task: URLSessionTask, continuation: Continuation) {
        let cancelled: Bool = lock.withLock {
            guard !isCancelled else { return true }
            self.continuation = continuation
            return false
        }
        if cancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            task.resume()
        }
    }

    func cancel(_ task: URLSessionTask) {
        lock.withLock { isCancelled = true }
        task.cancel()
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ outcome: Outcome) {
        let pending: Continuation? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: outcome)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Bearer keys and audio payloads never follow a redirect; the 3xx itself is delivered.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping (CachedURLResponse?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let rejection: Error? = lock.withLock {
            guard let http = response as? HTTPURLResponse else {
                return OpenRouterBoundedResponseTransport.Failure.invalidResponse
            }
            do {
                try accept(http)
            } catch {
                return error
            }
            guard http.expectedContentLength <= Int64(limit) else {
                return OpenRouterBoundedResponseTransport.Failure.responseTooLarge
            }
            if http.expectedContentLength > 0 { body.reserveCapacity(Int(http.expectedContentLength)) }
            self.response = http
            return nil
        }
        guard let rejection else {
            completionHandler(.allow)
            return
        }
        lock.withLock { failure = rejection }
        completionHandler(.cancel)
        resolve(.failure(rejection))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded: Bool = lock.withLock {
            guard failure == nil else { return false }
            guard body.count + data.count <= limit else {
                failure = OpenRouterBoundedResponseTransport.Failure.responseTooLarge
                return true
            }
            body.append(data)
            return false
        }
        guard exceeded else { return }
        dataTask.cancel()
        resolve(.failure(OpenRouterBoundedResponseTransport.Failure.responseTooLarge))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome: Outcome = lock.withLock {
            if let failure { return .failure(failure) }
            if let error { return .failure(error) }
            guard let response else { return .failure(OpenRouterBoundedResponseTransport.Failure.invalidResponse) }
            return .success(.init(http: response, body: body))
        }
        resolve(outcome)
    }
}

private class OpenRouterBoundedResponsePolicy: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Bearer keys and audio payloads never follow a redirect; the 3xx itself is delivered.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping (CachedURLResponse?) -> Void
    ) {
        completionHandler(nil)
    }

}
