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
        task.receive { result in
            completion(result.flatMap { message in
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

private final class StreamingSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var onOpen: (@Sendable () -> Void)?

    func install(_ callback: @escaping @Sendable () -> Void) { lock.withLock { onOpen = callback } }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        let callback = lock.withLock { onOpen }
        callback?()
    }
}
