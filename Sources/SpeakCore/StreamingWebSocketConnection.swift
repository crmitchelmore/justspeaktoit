import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Small injectable transport boundary; provider framing and lifecycle remain
/// in the shared client. Exactly one receiver and a bounded sender sit above it.
public enum StreamingWebSocketMessage: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

/// Implementations must deliver complete messages (assembling transport fragments),
/// call onOpen only after the handshake, and complete each send exactly once.
/// Cancellation must promptly release pending operations. Callbacks may arrive
/// after cancellation; the shared provider isolates them by session identity.
public protocol StreamingWebSocketConnection: AnyObject, Sendable {
    func resume(onOpen: @escaping @Sendable () -> Void)
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void)
    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)
    func cancel()
}

final class URLSessionStreamingConnection: StreamingWebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let delegate = StreamingSocketDelegate()

    init(session: URLSession, request: URLRequest) {
        var request = request
        #if canImport(FoundationNetworking)
        // corelibs 6.2.3 defaults to keep-alive, preventing curl from adding
        // the Upgrade token. Keep the server's RFC6455 contract intact.
        request.setValue("Upgrade", forHTTPHeaderField: "Connection")
        #endif
        self.task = session.webSocketTask(with: request)
        self.task.delegate = delegate
        self.task.maximumMessageSize = 1_024 * 1_024
    }

    func resume(onOpen: @escaping @Sendable () -> Void) {
        delegate.install(onOpen)
        task.resume()
    }

    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        let native: URLSessionWebSocketTask.Message
        switch message {
        case .text(let text): native = .string(text)
        case .binary(let data): native = .data(data)
        }
        task.send(native, completionHandler: completion)
    }

    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        let task = task, delegate = delegate
        task.receive { result in
            completion(result
                .mapError { error in
                    // Only this connection's own task can say how it closed:
                    // the close frame its delegate saw, or the code it recorded.
                    URLSessionWebSocketClosure.wrapping(error, closeCode: delegate.closeCode ?? task.peerCloseCode)
                }
                .flatMap { message in
                    switch message {
                    case .string(let text): return .success(.text(text))
                    case .data(let data): return .success(.binary(data))
                    @unknown default: return .failure(URLError(.cannotParseResponse))
                    }
                })
        }
    }

    func cancel() { task.cancel(with: .goingAway, reason: nil) }
}

/// A receive failure after a close frame on the failing connection's own task,
/// carrying that frame's status. A failure without one, such as a dropped
/// network, is passed through untouched and so reports no close at all.
struct URLSessionWebSocketClosure: StreamingWebSocketCloseReporting, LocalizedError {
    let webSocketCloseCode: Int?
    let underlying: Error

    /// Hosts keep showing the transport's own description.
    var errorDescription: String? { underlying.localizedDescription }

    static func wrapping(_ error: Error, closeCode: Int?) -> Error {
        guard let closeCode else { return error }
        return URLSessionWebSocketClosure(webSocketCloseCode: closeCode, underlying: error)
    }
}

private extension URLSessionWebSocketTask {
    /// The status of a close frame this task has seen, or nil before one.
    var peerCloseCode: Int? { closeCode == .invalid ? nil : closeCode.rawValue }
}

private final class StreamingSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var onOpen: (@Sendable () -> Void)?
    private var closeCodeValue: Int?

    /// The status of the close frame reported for this delegate's one task.
    var closeCode: Int? { lock.withLock { closeCodeValue } }

    func install(_ callback: @escaping @Sendable () -> Void) { lock.withLock { onOpen = callback } }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        let callback = lock.withLock { onOpen }
        callback?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // The receive completion carries closure to the shared lifecycle, with
        // this status attached.
        lock.withLock {
            onOpen = nil
            if closeCode != .invalid { closeCodeValue = closeCode.rawValue }
        }
    }
}
