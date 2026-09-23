import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LocalModelDownloadRequest: Sendable, Equatable {
    public let url: URL
    public let expectedByteCount: Int64
    public let allowedHosts: Set<String>
    /// Bytes already on disk. A positive offset asks the server for the rest.
    public let resumeOffset: Int64

    public init(url: URL, expectedByteCount: Int64, allowedHosts: Set<String>, resumeOffset: Int64 = 0) {
        self.url = url
        self.expectedByteCount = expectedByteCount
        self.allowedHosts = allowedHosts
        self.resumeOffset = resumeOffset
    }
}

/// How the server answered, reported once before any body bytes.
public enum LocalModelDownloadStart: Sendable, Equatable {
    /// The body is the whole file; existing partial bytes must be discarded.
    case fromBeginning
    /// The body continues the file at exactly this offset.
    case resumed(offset: Int64)
}

/// Streams a pinned artefact. Implementations never buffer the whole body.
public protocol LocalModelDownloadTransport: Sendable {
    /// Calls `start` once, then delivers the body to `sink` in order. Refuses
    /// non-HTTPS URLs, redirects outside `allowedHosts`, unexpected statuses
    /// and any length that would exceed the expected byte count.
    func download(
        _ request: LocalModelDownloadRequest,
        start: @escaping @Sendable (LocalModelDownloadStart) throws -> Void,
        sink: @escaping @Sendable (Data) throws -> Void
    ) async throws
}

public enum LocalModelDownloadError: LocalizedError, Equatable {
    case insecureURL
    case redirectRefused(String)
    case httpStatus(Int)
    case lengthMismatch(expected: Int64, actual: Int64)
    case rangeRefused
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .insecureURL: return "Local models download only over HTTPS from their pinned host."
        case .redirectRefused(let host):
            return "The download redirected to an unexpected host (\(host)) and was stopped."
        case .httpStatus(let code): return "The download server returned HTTP \(code). Try again later."
        case .lengthMismatch(let expected, let actual):
            return "The download was \(actual) bytes instead of the pinned \(expected). Nothing was installed."
        case .rangeRefused: return "The server could not resume the download."
        case .transport(let detail): return "The download failed: \(detail) Downloaded bytes are kept to resume."
        }
    }
}

/// URLSession transport with a streaming data delegate and HTTP range resume.
public final class LocalModelURLSessionTransport: LocalModelDownloadTransport {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 3_600
        self.configuration = configuration
    }

    public func download(
        _ request: LocalModelDownloadRequest,
        start: @escaping @Sendable (LocalModelDownloadStart) throws -> Void,
        sink: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        guard request.url.scheme == "https", let host = request.url.host?.lowercased(),
              request.allowedHosts.contains(host) else { throw LocalModelDownloadError.insecureURL }
        let delegate = StreamingDownloadDelegate(request: request, start: start, sink: sink)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.begin(session: session, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    struct ContentRange: Equatable {
        let first: Int64
        let last: Int64
        let total: Int64?
    }

    /// Parses `bytes <first>-<last>/<total>`.
    static func contentRange(_ value: String?) -> ContentRange? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), value.lowercased().hasPrefix("bytes ") else {
            return nil
        }
        let body = value.dropFirst("bytes ".count)
        let parts = body.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]), first <= last else {
            return nil
        }
        return ContentRange(first: first, last: last, total: parts[1] == "*" ? nil : Int64(parts[1]))
    }

    /// Decides how a response continues the file, or why it cannot.
    static func classify(
        status: Int, contentRange: String?, declaredLength: Int64, request: LocalModelDownloadRequest
    ) -> Result<LocalModelDownloadStart, LocalModelDownloadError> {
        switch status {
        case 200:
            guard declaredLength < 0 || declaredLength == request.expectedByteCount else {
                return .failure(.lengthMismatch(expected: request.expectedByteCount, actual: declaredLength))
            }
            return .success(.fromBeginning)
        case 206:
            guard request.resumeOffset > 0, let range = Self.contentRange(contentRange),
                  range.first == request.resumeOffset, range.last == request.expectedByteCount - 1,
                  range.total == nil || range.total == request.expectedByteCount else {
                return .failure(.rangeRefused)
            }
            return .success(.resumed(offset: range.first))
        case 416:
            return .failure(.rangeRefused)
        default:
            return .failure(.httpStatus(status))
        }
    }
}

private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: LocalModelDownloadRequest
    private let start: @Sendable (LocalModelDownloadStart) throws -> Void
    private let sink: @Sendable (Data) throws -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var failure: Error?
    private var cancelled = false
    private var expectedEnd: Int64 = 0
    private var received: Int64 = 0

    init(
        request: LocalModelDownloadRequest, start: @escaping @Sendable (LocalModelDownloadStart) throws -> Void,
        sink: @escaping @Sendable (Data) throws -> Void
    ) {
        self.request = request
        self.start = start
        self.sink = sink
    }

    func begin(session: URLSession, continuation: CheckedContinuation<Void, Error>) {
        var urlRequest = URLRequest(url: request.url)
        if request.resumeOffset > 0 {
            urlRequest.setValue("bytes=\(request.resumeOffset)-", forHTTPHeaderField: "Range")
        }
        let dataTask = session.dataTask(with: urlRequest)
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
        guard let http = response as? HTTPURLResponse else {
            fail(LocalModelDownloadError.httpStatus(0))
            completionHandler(.cancel)
            return
        }
        let outcome = LocalModelURLSessionTransport.classify(
            status: http.statusCode, contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            declaredLength: response.expectedContentLength, request: request
        )
        switch outcome {
        case .failure(let error):
            fail(error)
            completionHandler(.cancel)
        case .success(let begin):
            do {
                try start(begin)
                lock.withLock {
                    if case .resumed(let offset) = begin { received = offset } else { received = 0 }
                    expectedEnd = request.expectedByteCount
                }
                completionHandler(.allow)
            } catch {
                fail(error)
                completionHandler(.cancel)
            }
        }
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
        var redirected = newRequest
        if request.resumeOffset > 0 {
            redirected.setValue("bytes=\(request.resumeOffset)-", forHTTPHeaderField: "Range")
        }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome = lock.withLock { () -> Error? in
            if let failure { return failure }
            if cancelled { return CancellationError() }
            if let error { return LocalModelDownloadError.transport(error.localizedDescription) }
            guard received == expectedEnd, expectedEnd > 0 else {
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
