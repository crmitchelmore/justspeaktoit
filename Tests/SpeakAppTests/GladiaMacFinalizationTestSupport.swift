import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakApp

final class GladiaMacFixture: @unchecked Sendable {
    let factory = GladiaMacSocketFactory()
    let clock = GladiaMacClock()
    let client: GladiaLiveTranscriber
    private let session: URLSession
    private let lock = NSLock()
    private var failures: [Error] = []
    var onError: ((Error) -> Void)?
    var errors: [Error] { lock.withLock { failures } }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        self.session = session
        let factory = factory, clock = clock
        client = GladiaLiveTranscriber(
            apiKey: "synthetic", session: session, makeSocket: { factory.make($0) },
            beforeStopHandoff: { factory.beforeHandoff?() },
            didRegisterFinishWaiter: { factory.onFinishRegistered?() },
            schedule: { clock.schedule($0, action: $1) }
        )
    }
    deinit { client.stop(); session.invalidateAndCancel() }
    func record(_ error: Error) { lock.withLock { failures.append(error) }; onError?(error) }
}

final class GladiaMacOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: GladiaMacFinalization.Snapshot?
    var value: GladiaMacFinalization.Snapshot? { lock.withLock { result } }
    func store(_ value: GladiaMacFinalization.Snapshot) { lock.withLock { result = value } }
}

final class GladiaMacClock: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: [(TimeInterval, @Sendable () -> Void)] = []
    var delays: [TimeInterval] { lock.withLock { scheduled.map(\.0) } }
    func schedule(_ delay: TimeInterval, action: @escaping @Sendable () -> Void) {
        lock.withLock { scheduled.append((delay, action)) }
    }
    func fire() {
        let actions = lock.withLock { let all = scheduled; scheduled.removeAll(); return all }
        actions.forEach { $0.1() }
    }
}

final class GladiaMacSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [GladiaMacSocket] = []
    var onResume: ((Int) -> Void)?
    var beforeHandoff: (() -> Void)?
    var onFinishRegistered: (() -> Void)?
    var onStop: (() -> Void)?
    var onAudio: (() -> Void)?
    func socket(_ index: Int) -> GladiaMacSocket? {
        lock.withLock { sockets.indices.contains(index) ? sockets[index] : nil }
    }
    func make(_ request: URLRequest) -> GladiaMacSocket {
        XCTAssertEqual(request.url?.host, "api.gladia.io")
        let socket = GladiaMacSocket()
        let index = lock.withLock { let index = sockets.count; sockets.append(socket); return index }
        socket.onResume = { [weak self] in self?.onResume?(index) }
        socket.onStop = { [weak self] in self?.onStop?() }
        socket.onAudio = { [weak self] in self?.onAudio?() }
        return socket
    }
}

final class GladiaMacSocket: GladiaMacWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var status = URLSessionTask.State.suspended
    private var messages: [StreamingWebSocketMessage] = []
    private var sends: [@Sendable (Error?) -> Void] = []
    private var receiver: (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    private var incoming: [Result<URLSessionWebSocketTask.Message, Error>] = []
    private var cancellations = 0
    var onResume: (() -> Void)?
    var onStop: (() -> Void)?
    var onAudio: (() -> Void)?
    var state: URLSessionTask.State { lock.withLock { status } }
    var sent: [StreamingWebSocketMessage] { lock.withLock { messages } }
    var cancels: Int { lock.withLock { cancellations } }
    func resume() { lock.withLock { status = .running }; onResume?() }
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        let stored: StreamingWebSocketMessage
        switch message {
        case .string(let text): stored = .text(text)
        case .data(let data): stored = .binary(data)
        @unknown default: XCTFail("Unexpected message kind"); return
        }
        lock.withLock { messages.append(stored); sends.append(completionHandler) }
        if case .string = message { onStop?() } else { onAudio?() }
    }
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        let queued = lock.withLock { () -> Result<URLSessionWebSocketTask.Message, Error>? in
            guard !incoming.isEmpty else { receiver = completionHandler; return nil }
            return incoming.removeFirst()
        }
        if let queued { completionHandler(queued) }
    }
    func emit(_ text: String) {
        let result: Result<URLSessionWebSocketTask.Message, Error> = .success(.string(text))
        let callback = lock.withLock { () -> (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)? in
            guard let callback = receiver else { incoming.append(result); return nil }
            receiver = nil
            return callback
        }
        callback?(result)
    }
    func completeSend(error: Error? = nil) {
        let callback = lock.withLock { sends.isEmpty ? nil : sends.removeFirst() }
        XCTAssertNotNil(callback)
        callback?(error)
    }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock { status = .canceling; cancellations += 1 }
    }
}

final class GladiaMacHold: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    func wait() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while !released {
            if !condition.wait(until: deadline) { return released }
        }
        return true
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

final class GladiaMacCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}
