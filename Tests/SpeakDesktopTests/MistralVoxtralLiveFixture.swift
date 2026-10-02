import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Drives the real shared Mistral Voxtral client through the injected
/// transport seam. The fake socket, clock and event recorders are the ones the
/// AssemblyAI, Deepgram, OpenAI and xAI lifecycle tests use; only the frame
/// helpers here are shaped like the Voxtral Realtime socket. Every payload is
/// generated: no credential, recording or provider text is used or logged.
final class MistralVoxtralLiveFixture: @unchecked Sendable {
    let factory = AssemblyAISocketFactory()
    let clock = AssemblyAITestClock()
    let events = AssemblyAITestEvents()
    let client: MistralVoxtralLiveClient

    init(key: String = "synthetic", sampleRate: Int = 16_000) {
        let factory = factory, clock = clock
        client = MistralVoxtralLiveClient(
            apiKey: key, sampleRate: sampleRate,
            makeConnection: { factory.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
    }

    var socket: AssemblyAITestSocket { factory.sockets[0] }

    func start() {
        client.start(onTranscript: { [events] in events.transcript($0, final: $1) },
                     onError: { [events] in events.fail($0) })
    }

    /// The real handshake, `session.created`, and the completed send of the
    /// `session.update` it releases: the point from which audio may leave.
    func becomeReady() {
        socket.open()
        socket.sessionCreated()
        socket.completeSend()
    }

    /// Starts a finish and waits until the client has handed `type` to the
    /// transport, which proves the finish is registered.
    func finish(awaiting type: String, count: Int = 1) async -> Task<String?, Never> {
        let client = client
        let task = Task { await client.finishAndWait() }
        await settle { self.socket.types.filter { $0 == type }.count >= count }
        return task
    }

    /// Waits for a condition driven by another task, without a fixed sleep
    /// on any healthy path.
    func settle(_ condition: @escaping () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition was not reached")
    }

    /// Waits until the client has armed `count` deadlines of this length.
    func waitForScheduled(_ seconds: TimeInterval, count: Int = 1) async {
        await settle { self.clock.pending(seconds) >= count }
    }

    /// 100 ms of generated 16 kHz PCM16 mono whose bytes differ per frame, so
    /// order and fidelity are both visible in what was sent.
    static func frame(_ index: Int, count: Int = 3_200) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: index &* 31 &+ $0 &* 7) })
    }
}

/// Voxtral-shaped helpers on the shared fake socket. `objects`, `types` and
/// `sessionUpdate` come from the OpenAI Realtime fixture and decode the same
/// JSON text frames.
extension AssemblyAITestSocket {
    /// Frame types with consecutive repeats collapsed, for order assertions.
    var frameOrder: [String] {
        types.reduce(into: []) { order, type in if order.last != type { order.append(type) } }
    }

    /// The decoded PCM of each `input_audio.append`, in send order.
    var appendedAudio: [Data] {
        objects.filter { $0["type"] as? String == "input_audio.append" }
            .compactMap { ($0["audio"] as? String).flatMap { Data(base64Encoded: $0) } }
    }

    func sessionCreated() {
        emitMistral(["type": "session.created", "session": ["request_id": "ws-fixture", "model": "voxtral"]])
    }

    func delta(_ text: String) { emitMistral(["type": "transcription.text.delta", "text": text]) }

    func done(_ text: String) {
        emitMistral(["type": "transcription.done", "text": text, "language": "en", "segments": []])
    }

    func mistralError(_ message: String, code: Int) {
        emitMistral(["type": "error", "error": ["message": message, "code": code]])
    }

    func emitMistral(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return XCTFail("Invalid synthetic provider event")
        }
        emit(text)
    }
}

/// Measures how deeply transport calls nest. A client that sends its next
/// frame from inside a synchronous completion nests once per queued frame.
final class MistralReentrancyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var depth = 0
    private var deepest = 0
    var maximumDepth: Int { lock.withLock { deepest } }

    func enter() { lock.withLock { depth += 1; deepest = max(deepest, depth) } }
    func leave() { lock.withLock { depth -= 1 } }
}

/// A transport that answers each receive synchronously from a queue of
/// complete messages, as WinHTTP does when messages arrived first, and that
/// completes every send synchronously.
final class MistralSynchronousSocket: StreamingWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [StreamingWebSocketMessage] = []
    private var receiver: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)?
    private var sentValue: [String] = []
    let receives = MistralReentrancyProbe()
    let sends = MistralReentrancyProbe()
    var sent: [String] { lock.withLock { sentValue } }

    func queue(_ texts: [String]) { lock.withLock { queued.append(contentsOf: texts.map { .text($0) }) } }

    func resume(onOpen: @escaping @Sendable () -> Void) { onOpen() }

    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        sends.enter()
        if case .text(let text) = message { lock.withLock { sentValue.append(text) } }
        completion(nil)
        sends.leave()
    }

    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        let next: StreamingWebSocketMessage? = lock.withLock {
            guard !queued.isEmpty else { receiver = completion; return nil }
            return queued.removeFirst()
        }
        guard let next else { return }
        receives.enter()
        completion(.success(next))
        receives.leave()
    }

    /// Delivers queued messages to a receiver that is already waiting.
    func flush() {
        let waiting: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)? = lock.withLock {
            defer { receiver = nil }
            return receiver
        }
        guard let waiting else { return }
        receive(completion: waiting)
    }

    func cancel() {}
}
