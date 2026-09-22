import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LocalModelDownloadRequest: Sendable {
    public let url: URL
    public let expectedByteCount: Int64
    public let allowedHosts: Set<String>

    public init(url: URL, expectedByteCount: Int64, allowedHosts: Set<String>) {
        self.url = url
        self.expectedByteCount = expectedByteCount
        self.allowedHosts = allowedHosts
    }
}

/// Streams a pinned artefact. Implementations never buffer the whole body.
public protocol LocalModelDownloadTransport: Sendable {
    /// Delivers the response body to `sink` in order. Refuses non-HTTPS URLs,
    /// redirects to hosts outside `allowedHosts`, statuses other than 200 and
    /// any declared or actual length other than the expected byte count.
    func download(_ request: LocalModelDownloadRequest, sink: @escaping @Sendable (Data) throws -> Void) async throws
}

public enum LocalModelDownloadError: LocalizedError, Equatable {
    case insecureURL
    case redirectRefused(String)
    case httpStatus(Int)
    case lengthMismatch(expected: Int64, actual: Int64)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .insecureURL: return "Local models download only over HTTPS from their pinned host."
        case .redirectRefused(let host): return "The download redirected to an unexpected host (\(host)) and was stopped."
        case .httpStatus(let code): return "The download server returned HTTP \(code). Try again later."
        case .lengthMismatch(let expected, let actual):
            return "The download was \(actual) bytes instead of the pinned \(expected). Nothing was installed."
        case .transport(let detail): return "The download failed: \(detail)"
        }
    }
}

/// URLSession-based transport with a streaming data delegate.
public final class LocalModelURLSessionTransport: LocalModelDownloadTransport {
    /// GitHub serves release assets from github.com through its asset hosts.
    public static let gitHubReleaseHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"
    ]

    /// Redirect hosts admitted for a pinned URL: GitHub release assets may
    /// move to GitHub's asset hosts; any other pinned host only to itself.
    public static func allowedHosts(for url: URL) -> Set<String> {
        guard let host = url.host?.lowercased() else { return [] }
        return host == "github.com" ? gitHubReleaseHosts : [host]
    }

    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        self.configuration = configuration
    }

    public func download(
        _ request: LocalModelDownloadRequest, sink: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        guard request.url.scheme == "https", let host = request.url.host?.lowercased(),
              request.allowedHosts.contains(host) else { throw LocalModelDownloadError.insecureURL }
        let delegate = StreamingDownloadDelegate(request: request, sink: sink)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(session: session, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: LocalModelDownloadRequest
    private let sink: @Sendable (Data) throws -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var failure: Error?
    private var cancelled = false
    private var received: Int64 = 0

    init(request: LocalModelDownloadRequest, sink: @escaping @Sendable (Data) throws -> Void) {
        self.request = request
        self.sink = sink
    }

    func start(session: URLSession, continuation: CheckedContinuation<Void, Error>) {
        let dataTask = session.dataTask(with: URLRequest(url: request.url))
        let startNow = lock.withLock { () -> Bool in
            self.continuation = continuation
            self.task = dataTask
            return !cancelled
        }
        guard startNow else {
            finish(CancellationError())
            return
        }
        dataTask.resume()
    }

    func cancel() {
        let pending = lock.withLock { () -> URLSessionDataTask? in
            cancelled = true
            return task
        }
        pending?.cancel()
    }

    private func fail(_ error: Error) {
        let pending = lock.withLock { () -> URLSessionDataTask? in
            if failure == nil { failure = error }
            return task
        }
        pending?.cancel()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            fail(LocalModelDownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0))
            completionHandler(.cancel)
            return
        }
        let declared = response.expectedContentLength
        guard declared < 0 || declared == request.expectedByteCount else {
            fail(LocalModelDownloadError.lengthMismatch(expected: request.expectedByteCount, actual: declared))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let total = lock.withLock { () -> Int64? in
            guard failure == nil, !cancelled else { return nil }
            received += Int64(data.count)
            return received
        }
        guard let total else { return }
        guard total <= request.expectedByteCount else {
            fail(LocalModelDownloadError.lengthMismatch(expected: request.expectedByteCount, actual: total))
            return
        }
        do { try sink(data) } catch { fail(error) }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let host = newRequest.url?.host?.lowercased() ?? ""
        guard newRequest.url?.scheme == "https", request.allowedHosts.contains(host) else {
            fail(LocalModelDownloadError.redirectRefused(host))
            completionHandler(nil)
            return
        }
        completionHandler(newRequest)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome = lock.withLock { () -> Error? in
            if let failure { return failure }
            if cancelled { return CancellationError() }
            if let error { return LocalModelDownloadError.transport(error.localizedDescription) }
            guard received == request.expectedByteCount else {
                return LocalModelDownloadError.lengthMismatch(expected: request.expectedByteCount, actual: received)
            }
            return nil
        }
        finish(outcome)
    }

    private func finish(_ error: Error?) {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let pending = continuation
            continuation = nil
            return pending
        }
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
