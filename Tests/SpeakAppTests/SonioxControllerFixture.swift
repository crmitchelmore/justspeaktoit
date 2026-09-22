import Foundation
import SpeakCore
@testable import SpeakApp

/// Fake wire, with completions controlled by the test rather than sleeps.
final class SonioxControllerSocket: StreamingWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var opener: (@Sendable () -> Void)?
    private var receiver: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)?
    private var completions: [@Sendable (Error?) -> Void] = []
    private var messages: [StreamingWebSocketMessage] = []
    private var cancelled = false

    var isCancelled: Bool { self.lock.withLock { self.cancelled } }
    var binary: [Data] {
        self.lock.withLock {
            self.messages.compactMap { if case .binary(let data) = $0 { data } else { nil } }
        }
    }
    var controls: [String] {
        self.lock.withLock {
            self.messages.compactMap { if case .text(let text) = $0 { text } else { nil } }
        }
    }
    func resume(onOpen: @escaping @Sendable () -> Void) { self.lock.withLock { self.opener = onOpen } }
    func open() { self.lock.withLock { self.opener }?() }
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        self.lock.withLock { self.messages.append(message); self.completions.append(completion) }
    }
    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        self.lock.withLock { self.receiver = completion }
    }
    func completeSend() {
        let callback = self.lock.withLock { self.completions.isEmpty ? nil : self.completions.removeFirst() }
        callback?(nil)
    }
    func emit(_ text: String) {
        let callback = self.lock.withLock {
            let value = self.receiver
            self.receiver = nil
            return value
        }
        callback?(.success(.text(text)))
    }
    func cancel() { self.lock.withLock { self.cancelled = true } }
}

final class SonioxControllerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [(TimeInterval, @Sendable () -> Void)] = []
    var delays: [TimeInterval] { self.lock.withLock { self.actions.map(\.0) } }
    func schedule(_ delay: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        self.lock.withLock { self.actions.append((delay, action)) }
    }
    func fire(_ delay: TimeInterval) {
        let callbacks = self.lock.withLock {
            let selected = self.actions.filter { $0.0 == delay }
            self.actions.removeAll { $0.0 == delay }
            return selected
        }
        callbacks.forEach { $0.1() }
    }
}

final class SonioxControllerFixture {
    let socket = SonioxControllerSocket()
    let clock = SonioxControllerClock()
    let adapter: SonioxControllerClient

    init(language: String? = nil) {
        let socket = self.socket, clock = self.clock
        let client = SonioxLiveClient(
            apiKey: "synthetic", model: "stt-rt-v5", language: language,
            makeConnection: { _ in socket }, schedule: { clock.schedule($0, $1) },
            finishTimeout: SonioxControllerClient.finishTimeout
        )
        self.adapter = SonioxControllerClient(client: client)
    }
    func start() { self.adapter.start(onTranscript: { _, _ in }, onError: { _ in }) }
    func ready() { self.socket.open(); self.socket.completeSend() }
}

/// Deliberately retains callbacks after cancel, to model stale provider work.
final class SonioxControllerFakeClient: FinalizingStreamingTranscriptionClient {
    let finalShape: TranscriptFinalShape = .cumulativeTranscript
    var transcript: ((String, Bool) -> Void)?
    var error: ((Error) -> Void)?
    var result: String?
    var onFinish: (() -> Void)?
    var starts = 0
    var cancels = 0
    var audio: [Data] = []
    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        self.starts += 1
        self.transcript = onTranscript
        self.error = onError
    }
    func sendAudio(_ data: Data) { self.audio.append(data) }
    func stop() { self.cancel() }
    func cancel() { self.cancels += 1 }
    func finishAndWait() async -> String? { self.onFinish?(); return self.result }
}
