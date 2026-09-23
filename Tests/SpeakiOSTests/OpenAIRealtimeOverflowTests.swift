import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

final class OpenAIRealtimeOverflowTests: XCTestCase {
    func testBelowAndExactlyAtCap_flushAcceptedPCMOnAcknowledgement() {
        let (client, socket) = makeClient()
        var errors: [Error] = []
        client.start(onEvent: { _ in }, onError: { errors.append($0) })
        let prefix = Data(repeating: 7, count: 240_000 - 4_800)
        let last = Data(repeating: 9, count: 4_800)
        client.sendAudio(prefix)
        XCTAssertEqual(client.bufferedAudioBytes, prefix.count)
        client.sendAudio(last)
        XCTAssertEqual(client.bufferedAudioBytes, 240_000)
        XCTAssertTrue(socket.audio.isEmpty)
        socket.acknowledge()
        XCTAssertEqual(socket.audio, [prefix, last])
        XCTAssertEqual(client.bufferedAudioBytes, 0)
        client.sendAudio(last)
        XCTAssertEqual(socket.audio, [prefix, last, last])
        XCTAssertTrue(errors.isEmpty)
        client.stop()
    }

    func testCrossingChunk_reportsOnceReentrantlyAndStopsAdmissionAfterAcknowledgement() {
        let (client, socket) = makeClient()
        var errors: [Error] = []
        client.start(onEvent: { _ in }, onError: {
            errors.append($0)
            XCTAssertEqual(client.bufferedAudioBytes, 239_998, "Callback must be able to re-enter the client")
        })
        let prefix = Data(repeating: 7, count: 239_998)
        client.sendAudio(prefix)
        client.sendAudio(Data(repeating: 9, count: 4_800))
        for _ in 0..<100 { client.sendAudio(Data(repeating: 9, count: 4_800)) }
        XCTAssertEqual(client.bufferedAudioBytes, prefix.count)
        XCTAssertEqual(errors.count, 1)
        guard case .preReadyAudioOverflow? = errors.first as? OpenAIRealtimeError else {
            return XCTFail("Expected the platform overflow error")
        }
        socket.acknowledge()
        client.sendAudio(Data(repeating: 1, count: 2))
        client.commitInputBuffer()
        XCTAssertEqual(socket.audio, [prefix], "Only the accepted prefix may be finalised")
        XCTAssertEqual(socket.types.filter { $0 == "input_audio_buffer.commit" }.count, 1)
        XCTAssertEqual(errors.count, 1)
        client.stop()
    }

    func testOverflowCallbackCanStopAndLateAcknowledgementCannotFlushCancelledAudio() {
        let (client, socket) = makeClient()
        var errorCount = 0
        client.start(onEvent: { _ in }, onError: { _ in
            errorCount += 1
            client.stop()
        })
        client.sendAudio(Data(repeating: 0, count: 240_000))
        client.sendAudio(Data(repeating: 0, count: 2))
        socket.acknowledge()
        XCTAssertEqual(errorCount, 1)
        XCTAssertEqual(client.bufferedAudioBytes, 0)
        XCTAssertTrue(socket.audio.isEmpty)
        XCTAssertTrue(socket.isCancelled)
    }

    func testConcurrentAcknowledgementOverflowAndStop_stayBoundedAndReportAtMostOnce() {
        for _ in 0..<30 {
            let (client, socket) = makeClient()
            let errors = LockedOverflowCounter()
            client.start(onEvent: { _ in }, onError: { _ in errors.increment() })
            client.sendAudio(Data(repeating: 0, count: 240_000))
            DispatchQueue.concurrentPerform(iterations: 3) { index in
                switch index {
                case 0: client.sendAudio(Data(repeating: 1, count: 4_800))
                case 1: socket.acknowledge()
                default: client.stop()
                }
            }
            XCTAssertLessThanOrEqual(errors.count, 1)
            XCTAssertEqual(client.bufferedAudioBytes, 0)
        }
    }

    func testFreshClientAcceptsAudioAfterPreviousOverflow() {
        let (old, oldSocket) = makeClient()
        var errors = 0
        old.start(onEvent: { _ in }, onError: { _ in errors += 1 })
        old.sendAudio(Data(repeating: 0, count: 240_002))
        old.stop()
        let (fresh, socket) = makeClient()
        fresh.start(onEvent: { _ in }, onError: { _ in XCTFail("Fresh run must not inherit overflow") })
        oldSocket.acknowledge()
        let pcm = Data(repeating: 1, count: 4_800)
        fresh.sendAudio(pcm)
        socket.acknowledge()
        XCTAssertEqual(socket.audio, [pcm])
        XCTAssertEqual(errors, 1)
        fresh.stop()
    }

    func testRestartResetsOverflowAndIgnoresOldSocketAcknowledgement() {
        let sockets = OverflowSocketHolder()
        let client = OpenAIRealtimeWebSocketClient(
            apiKey: "synthetic-test-key", model: "gpt-live-transcribe", language: nil, sampleRate: 24_000,
            makeConnection: { _ in sockets.next() }
        )
        client.start(onEvent: { _ in }, onError: { _ in })
        let oldSocket = sockets.current
        client.sendAudio(Data(repeating: 0, count: 240_002))
        client.stop()
        var errors = 0
        client.start(onEvent: { _ in }, onError: { _ in errors += 1 })
        let socket = sockets.current
        XCTAssertFalse(socket === oldSocket)
        let pcm = Data(repeating: 1, count: 4_800)
        client.sendAudio(pcm)
        oldSocket.acknowledge()
        XCTAssertTrue(socket.audio.isEmpty, "Only the current socket can acknowledge this run")
        XCTAssertEqual(client.bufferedAudioBytes, pcm.count)
        socket.acknowledge()
        XCTAssertEqual(socket.audio, [pcm])
        XCTAssertEqual(errors, 0)
        client.stop()
    }

    func testAcknowledgementFlushesThePrefixBeforeReadinessResumesAndCommitFollowsIt() async {
        let (client, socket) = makeClient()
        client.start(onEvent: { _ in }, onError: { _ in })
        client.sendAudio(Data(repeating: 0, count: 240_000))
        client.sendAudio(Data(repeating: 0, count: 2))
        let readyBeforeAcknowledgement = await client.awaitSessionReady(timeout: 0.01)
        XCTAssertFalse(readyBeforeAcknowledgement)
        XCTAssertTrue(socket.audio.isEmpty)
        socket.acknowledge()
        let readyAfterFlush = await client.awaitSessionReady(timeout: 2)
        XCTAssertTrue(readyAfterFlush)
        XCTAssertEqual(socket.audio.count, 1)
        await client.waitForPendingSends()
        client.commitInputBuffer()
        XCTAssertEqual(socket.types.suffix(2), ["input_audio_buffer.append", "input_audio_buffer.commit"])
        client.stop()
    }

    func testLiveAudioCannotOvertakeThePrefixQueuedBeforeAcknowledgement() {
        let (client, socket) = makeClient()
        client.start(onEvent: { _ in }, onError: { _ in XCTFail("Healthy startup failed") })
        let first = Data(repeating: 1, count: 4_800)
        let second = Data(repeating: 2, count: 4_800)
        let live = Data(repeating: 3, count: 4_800)
        client.sendAudio(first)
        client.sendAudio(second)
        socket.acknowledge()
        client.sendAudio(live)
        XCTAssertEqual(socket.audio, [first, second, live])
        client.stop()
    }

    func testEmptyRecordingCommitsNothingAndStopClosesImmediately() {
        let (client, socket) = makeClient()
        client.start(onEvent: { _ in }, onError: { _ in XCTFail("Empty recording must not fail") })
        socket.acknowledge()
        client.commitInputBuffer()
        XCTAssertEqual(socket.types, ["session.update"])
        client.stop()
        XCTAssertTrue(socket.isCancelled)
    }

    private func makeClient() -> (OpenAIRealtimeWebSocketClient, OverflowTestSocket) {
        let socket = OverflowTestSocket()
        let client = OpenAIRealtimeWebSocketClient(
            apiKey: "synthetic-test-key", model: "gpt-live-transcribe", language: nil, sampleRate: 24_000,
            makeConnection: { _ in socket }
        )
        return (client, socket)
    }
}

/// Fake transport at the shared connection seam: it opens on resume the way a
/// URLSession task queues sends until its handshake, completes every send at
/// once, and records the decoded JSON frames it was handed. Tests deliver
/// parsed provider events; they do not substitute another buffer implementation.
final class OverflowTestSocket: StreamingWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [[String: Any]] = []
    private var receiver: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)?
    private var cancelled = false

    var types: [String] { lock.withLock { messages.compactMap { $0["type"] as? String } } }
    var audio: [Data] {
        lock.withLock { messages.compactMap { ($0["audio"] as? String).flatMap { Data(base64Encoded: $0) } } }
    }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func resume(onOpen: @escaping @Sendable () -> Void) { onOpen() }
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        if case .text(let text) = message,
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            lock.withLock { messages.append(object) }
        }
        completion(nil)
    }
    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        lock.withLock { receiver = completion }
    }
    func cancel() { lock.withLock { cancelled = true } }
    func acknowledge() { emit(["type": "session.updated", "session": ["type": "transcription"]]) }
    func emit(_ payload: [String: Any]) {
        let callback = lock.withLock {
            let callback = receiver
            receiver = nil
            return callback
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return XCTFail("Invalid synthetic provider event")
        }
        callback?(.success(.text(text)))
    }
}

private final class OverflowSocketHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = OverflowTestSocket()
    var current: OverflowTestSocket { lock.withLock { latest } }
    func next() -> OverflowTestSocket {
        lock.withLock {
            latest = OverflowTestSocket()
            return latest
        }
    }
}

private final class LockedOverflowCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
