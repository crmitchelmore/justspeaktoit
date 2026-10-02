import Foundation
@testable import SpeakCore

/// A scripted `StreamingWebSocketConnection` for the shared live clients. It
/// opens as soon as it is resumed (unless told to wait), completes sends
/// automatically unless held, and records frames in `URLSessionWebSocketTask`
/// terms so tests read naturally.
final class TestLiveWebSocket: StreamingWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var storedState: URLSessionTask.State = .suspended
    private var storedCloseCode: URLSessionWebSocketTask.CloseCode = .invalid
    private var opener: (@Sendable () -> Void)?
    private var receivers: [@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void] = []
    private var inbound: [Result<StreamingWebSocketMessage, Error>] = []
    private var sendCompletions: [@Sendable (Error?) -> Void] = []
    private var storedMessages: [URLSessionWebSocketTask.Message] = []
    private var storedCancelCount = 0
    var automaticallyCompletesSends = true
    var automaticallyRunsOnResume = true

    var state: URLSessionTask.State { lock.withLock { storedState } }
    var closeCode: URLSessionWebSocketTask.CloseCode { lock.withLock { storedCloseCode } }
    var messages: [URLSessionWebSocketTask.Message] { lock.withLock { storedMessages } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }

    func resume(onOpen: @escaping @Sendable () -> Void) {
        let openNow = lock.withLock { () -> Bool in
            opener = onOpen
            guard automaticallyRunsOnResume else { return false }
            storedState = .running
            return true
        }
        if openNow { onOpen() }
    }

    /// Completes a handshake that was held by `automaticallyRunsOnResume = false`.
    func markRunning() {
        let open = lock.withLock { () -> (@Sendable () -> Void)? in
            storedState = .running
            return opener
        }
        open?()
    }

    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        let completeNow = lock.withLock { () -> Bool in
            switch message {
            case .text(let text): storedMessages.append(.string(text))
            case .binary(let data): storedMessages.append(.data(data))
            }
            if !automaticallyCompletesSends { sendCompletions.append(completion) }
            return automaticallyCompletesSends
        }
        if completeNow { completion(nil) }
    }

    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        let result = lock.withLock { () -> Result<StreamingWebSocketMessage, Error>? in
            if !inbound.isEmpty { return inbound.removeFirst() }
            receivers.append(completion)
            return nil
        }
        if let result { completion(result) }
    }

    func cancel() {
        lock.withLock {
            storedCancelCount += 1
            storedState = .canceling
        }
    }

    func emit(_ text: String) { deliver(.success(.text(text))) }
    func failReceive(_ error: Error = URLError(.networkConnectionLost)) { deliver(.failure(error)) }

    /// The server's close frame, reported the way the shared transport does.
    func closeFromServer(_ code: URLSessionWebSocketTask.CloseCode = .normalClosure) {
        lock.withLock { storedCloseCode = code }
        deliver(.failure(TestWebSocketClosure(webSocketCloseCode: code.rawValue)))
    }

    private func deliver(_ result: Result<StreamingWebSocketMessage, Error>) {
        let receiver = lock.withLock { () -> (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)? in
            if receivers.isEmpty {
                inbound.append(result)
                return nil
            }
            return receivers.removeFirst()
        }
        receiver?(result)
    }

    func completeNextSend(_ error: Error? = nil) {
        let completion = lock.withLock { sendCompletions.isEmpty ? nil : sendCompletions.removeFirst() }
        completion?(error)
    }
}

/// A receive failure that carries the peer's close code, as
/// `URLSessionStreamingConnection` reports one.
struct TestWebSocketClosure: StreamingWebSocketCloseReporting {
    let webSocketCloseCode: Int?
}

final class TestSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [TestLiveWebSocket]
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { storedRequests } }

    init(_ sockets: [TestLiveWebSocket]) { self.sockets = sockets }

    func make(_ request: URLRequest) -> any StreamingWebSocketConnection {
        lock.withLock {
            storedRequests.append(request)
            return sockets.removeFirst()
        }
    }
}

func eventually(
    timeout: TimeInterval = 1,
    _ predicate: @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return predicate()
}

func textMessages(_ socket: TestLiveWebSocket) -> [String] {
    socket.messages.compactMap {
        guard case .string(let text) = $0 else { return nil }
        return text
    }
}
