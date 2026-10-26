import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

final class CartesiaMacFixture: @unchecked Sendable {
    let socket = CartesiaMacSocket()
    let clock = CartesiaMacClock()
    let core: CartesiaLiveClient
    let adapter: CartesiaLiveTranscriber
    private let lock = NSLock()
    private var texts: [String] = []
    var delivered: [String] { lock.withLock { texts } }
    var onError: ((Error) -> Void)?

    init() {
        let socket = socket, clock = clock
        core = CartesiaLiveClient(
            apiKey: "synthetic", postStopFinalizeBudget: 1.5, stopGracePeriod: 0.3,
            makeConnection: { _ in socket }, schedule: { clock.schedule($0, action: $1) }
        )
        adapter = CartesiaLiveTranscriber(client: core)
    }
    func start() {
        adapter.start(onTranscript: { [weak self] text, _ in
            self?.lock.withLock { self?.texts.append(text) }
        }, onError: { [weak self] error in self?.onError?(error) })
        socket.open()
    }
}

final class CartesiaMacOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: CartesiaLiveTranscriber.Snapshot?
    var value: CartesiaLiveTranscriber.Snapshot? { lock.withLock { result } }
    func store(_ value: CartesiaLiveTranscriber.Snapshot) { lock.withLock { result = value } }
}

final class CartesiaMacClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    var delays: [TimeInterval] { lock.withLock { values } }
    func schedule(_ delay: TimeInterval, action: @escaping @Sendable () -> Void) {
        lock.withLock { values.append(delay) }
    }
}

final class CartesiaMacSocket: StreamingWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var opener: (@Sendable () -> Void)?
    private var receiver: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)?
    private var messages: [StreamingWebSocketMessage] = []
    private var completions: [@Sendable (Error?) -> Void] = []
    private var cancellations = 0
    private var resumeCount = 0
    var onClose: (() -> Void)?
    var onAudio: ((Data) -> Void)?
    var resumes: Int { lock.withLock { resumeCount } }
    var cancels: Int { lock.withLock { cancellations } }
    var binary: [Data] {
        lock.withLock { messages.compactMap { if case .binary(let data) = $0 { data } else { nil } } }
    }
    var text: [String] {
        lock.withLock { messages.compactMap { if case .text(let text) = $0 { text } else { nil } } }
    }
    func resume(onOpen: @escaping @Sendable () -> Void) {
        lock.withLock { opener = onOpen; resumeCount += 1 }
    }
    func open() { lock.withLock { opener }?() }
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { messages.append(message); completions.append(completion) }
        switch message {
        case .text: onClose?()
        case .binary(let data): onAudio?(data)
        }
    }
    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        lock.withLock { receiver = completion }
    }
    func emit(_ text: String) { deliver(.success(.text(text))) }
    func closeNormally() { deliver(.failure(CartesiaMacPeerClose())) }
    private func deliver(_ result: Result<StreamingWebSocketMessage, Error>) {
        let callback = lock.withLock { let callback = receiver; receiver = nil; return callback }
        callback?(result)
    }
    func completeSend(error: Error? = nil) {
        let completion = lock.withLock { completions.isEmpty ? nil : completions.removeFirst() }
        XCTAssertNotNil(completion)
        completion?(error)
    }
    func cancel() { lock.withLock { cancellations += 1 } }
}

private struct CartesiaMacPeerClose: StreamingWebSocketCloseReporting { let webSocketCloseCode: Int? = 1000 }

final class CartesiaMacHold: @unchecked Sendable {
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
