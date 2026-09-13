import Foundation
@testable import SpeakCore

final class TestLiveWebSocket: LiveWebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedState: URLSessionTask.State = .suspended
    private var receivers: [@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void] = []
    private var inbound: [Result<URLSessionWebSocketTask.Message, Error>] = []
    private var sendCompletions: [@Sendable (Error?) -> Void] = []
    private var storedMessages: [URLSessionWebSocketTask.Message] = []
    private var storedCancelCount = 0
    var automaticallyCompletesSends = true

    var state: URLSessionTask.State { lock.withLock { storedState } }
    var messages: [URLSessionWebSocketTask.Message] { lock.withLock { storedMessages } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }

    func resume() { lock.withLock { storedState = .running } }

    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping @Sendable (Error?) -> Void) {
        let completeNow = lock.withLock { () -> Bool in
            storedMessages.append(message)
            if !automaticallyCompletesSends { sendCompletions.append(completion) }
            return automaticallyCompletesSends
        }
        if completeNow { completion(nil) }
    }

    func receive(completion: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        let result = lock.withLock { () -> Result<URLSessionWebSocketTask.Message, Error>? in
            if !inbound.isEmpty { return inbound.removeFirst() }
            receivers.append(completion)
            return nil
        }
        if let result { completion(result) }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock {
            storedCancelCount += 1
            storedState = .canceling
        }
    }

    func emit(_ text: String) { deliver(.success(.string(text))) }
    func failReceive(_ error: Error = URLError(.networkConnectionLost)) { deliver(.failure(error)) }

    private func deliver(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        let receiver = lock.withLock { () -> (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)? in
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

final class TestSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [TestLiveWebSocket]
    private(set) var requests: [URLRequest] = []

    init(_ sockets: [TestLiveWebSocket]) { self.sockets = sockets }

    func make(_ request: URLRequest) -> LiveWebSocketTransport {
        lock.withLock {
            requests.append(request)
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
