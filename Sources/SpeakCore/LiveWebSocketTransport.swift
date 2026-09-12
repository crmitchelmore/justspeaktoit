import Foundation

/// Narrow transport seam for shared clients whose stop ordering must be tested
/// without opening a paid provider connection.
protocol LiveWebSocketTransport: AnyObject, Sendable {
    var state: URLSessionTask.State { get }
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping @Sendable (Error?) -> Void)
    func receive(
        completion: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    )
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

final class URLSessionLiveWebSocketTransport: LiveWebSocketTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    var state: URLSessionTask.State { task.state }
    var closeCode: URLSessionWebSocketTask.CloseCode { task.closeCode }
    func resume() { task.resume() }
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping @Sendable (Error?) -> Void) {
        task.send(message, completionHandler: completion)
    }
    func receive(
        completion: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ) {
        task.receive(completionHandler: completion)
    }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
    }
}

typealias LiveWebSocketFactory = @Sendable (URLRequest) -> LiveWebSocketTransport
