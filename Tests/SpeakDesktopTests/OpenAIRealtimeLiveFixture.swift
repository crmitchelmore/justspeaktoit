import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Drives the real shared client through the injected transport seam. The
/// fake socket, clock and event recorders are the same ones the AssemblyAI and
/// Deepgram lifecycle tests use; only the JSON helpers here are OpenAI-shaped.
final class OpenAIRealtimeLiveFixture: @unchecked Sendable {
    let factory = AssemblyAISocketFactory()
    let clock = AssemblyAITestClock()
    let events = AssemblyAITestEvents()
    let canonical = OpenAIRealtimeCanonicalEvents()
    let client: OpenAIRealtimeLiveClient

    init(
        key: String = "synthetic", model: String = "gpt-live-transcribe", language: String? = nil,
        prompt: String? = nil, sampleRate: Int = 24_000, finalizeBudget: TimeInterval? = nil
    ) {
        let factory = factory, clock = clock
        client = OpenAIRealtimeLiveClient(
            apiKey: key, model: model, language: language, prompt: prompt, sampleRate: sampleRate,
            finalizeBudget: finalizeBudget,
            makeConnection: { factory.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
    }

    var socket: AssemblyAITestSocket { factory.sockets[0] }

    /// Shared `onTranscript` surface used by desktop hosts.
    func start() {
        client.start(onTranscript: { [events] in events.transcript($0, final: $1) },
                     onError: { [events] in events.fail($0) })
    }

    /// Canonical per-item event surface used by the Apple controllers.
    func startCanonical() {
        client.start(onEvent: { [canonical] in canonical.record($0) }, onError: { [events] in events.fail($0) })
    }

    /// Real handshake, our `session.update` completing, then its acknowledgement.
    func becomeReady() {
        socket.open()
        socket.completeSend()
        socket.acknowledge()
    }

    /// Waits until the client has armed a deadline of exactly this length, which
    /// proves an asynchronous wait has registered on the state queue.
    func waitForScheduled(_ seconds: TimeInterval) async {
        for _ in 0..<400 {
            if clock.pending(seconds) > 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("No \(seconds)s deadline was scheduled")
    }

    func settle(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "Condition did not settle")
    }
}

/// Transport that opens on resume and completes every send at once, so the
/// client's reentrant completion path runs synchronously under concurrency.
final class OpenAIRealtimeAutoSocket: StreamingWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)?
    private var sentValue: [String] = []
    private var cancelled = false
    var sent: [String] { lock.withLock { sentValue } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func resume(onOpen: @escaping @Sendable () -> Void) { onOpen() }
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        if case .text(let text) = message { lock.withLock { sentValue.append(text) } }
        completion(nil)
    }
    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        lock.withLock { receiver = completion }
    }
    func cancel() { lock.withLock { cancelled = true } }
    func acknowledge() {
        let callback = lock.withLock { let value = receiver; receiver = nil; return value }
        callback?(.success(.text(#"{"type":"session.updated","session":{"type":"transcription"}}"#)))
    }
}

final class OpenAIRealtimeCanonicalEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OpenAIRealtimeLiveClient.Event] = []
    var all: [OpenAIRealtimeLiveClient.Event] { lock.withLock { values } }
    func record(_ event: OpenAIRealtimeLiveClient.Event) { lock.withLock { values.append(event) } }
}

extension AssemblyAITestSocket {
    /// Every text frame as a JSON object, in send order.
    var objects: [[String: Any]] {
        controls.compactMap { text in
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    var types: [String] { objects.compactMap { $0["type"] as? String } }

    /// Decoded PCM of every `input_audio_buffer.append`, in send order.
    var audio: [Data] {
        objects.compactMap { object in
            guard object["type"] as? String == "input_audio_buffer.append",
                  let base64 = object["audio"] as? String else { return nil }
            return Data(base64Encoded: base64)
        }
    }

    var sessionUpdate: [String: Any]? { objects.first { $0["type"] as? String == "session.update" } }

    /// Fulfils once the client hands `input_audio_buffer.commit` to the transport.
    func fulfillOnCommit(_ expectation: XCTestExpectation) {
        onSend = { message in
            if case .text(let text) = message, text.contains("input_audio_buffer.commit") { expectation.fulfill() }
        }
    }

    func acknowledge(sessionType: String? = "transcription") {
        var session: [String: Any] = ["id": "sess_1"]
        if let sessionType { session["type"] = sessionType }
        emitObject(["type": "session.updated", "session": session])
    }

    func created() { emitObject(["type": "session.created", "session": ["id": "sess_1"]]) }

    func committed(_ itemID: String, previous: String? = nil) {
        emitObject(["type": "input_audio_buffer.committed", "item_id": itemID, "previous_item_id": previous as Any])
    }

    func delta(_ text: String, item: String) {
        emitObject(["type": "conversation.item.input_audio_transcription.delta", "item_id": item, "delta": text])
    }

    func completed(_ text: String, item: String) {
        emitObject([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": item, "transcript": text
        ])
    }

    func transcriptionFailed(item: String, message: String) {
        emitObject([
            "type": "conversation.item.input_audio_transcription.failed", "item_id": item,
            "error": ["code": "audio_unintelligible", "message": message]
        ])
    }

    func serverError(code: String = "invalid_request_error", message: String = "Synthetic failure") {
        emitObject(["type": "error", "error": ["code": code, "message": message]])
    }

    private func emitObject(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return XCTFail("Invalid synthetic provider event")
        }
        emit(text)
    }
}
