import Foundation
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

    func testCrossingChunk_reportsOnceOutsideLockAndStopsAdmissionAfterAcknowledgement() {
        let (client, socket) = makeClient()
        var errors: [Error] = []
        client.start(onEvent: { _ in }, onError: {
            errors.append($0)
            XCTAssertEqual(client.bufferedAudioBytes, 239_998, "Callback must run outside the state lock")
        })
        let prefix = Data(repeating: 7, count: 239_998)
        client.sendAudio(prefix)
        client.sendAudio(Data(repeating: 9, count: 4_800))
        for _ in 0..<100 { client.sendAudio(Data(repeating: 9, count: 4_800)) }
        XCTAssertEqual(client.bufferedAudioBytes, prefix.count)
        XCTAssertEqual(errors.count, 1)
        guard case .preReadyAudioOverflow? = errors.first as? OpenAIRealtimeError else {
            return XCTFail("Expected the explicit overflow error")
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
        var socket = OverflowTestSocket()
        let client = OpenAIRealtimeWebSocketClient(
            apiKey: "synthetic-test-key", model: "gpt-live-transcribe", language: nil, sampleRate: 24_000,
            makeSocket: { _ in socket }
        )
        client.start(onEvent: { _ in }, onError: { _ in })
        client.sendAudio(Data(repeating: 0, count: 240_002))
        let oldSocket = socket
        client.stop()
        socket = OverflowTestSocket()
        var errors = 0
        client.start(onEvent: { _ in }, onError: { _ in errors += 1 })
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

    func testAcknowledgementDoesNotReleaseStopBeforePrefixEntersSendGroup() async {
        let (client, socket) = makeClient()
        let enteredSend = expectation(description: "Prefix send entered")
        let releaseSend = DispatchSemaphore(value: 0)
        socket.beforeAudioSend = {
            enteredSend.fulfill()
            _ = releaseSend.wait(timeout: .now() + 5)
        }
        client.start(onEvent: { _ in }, onError: { _ in })
        client.sendAudio(Data(repeating: 0, count: 240_000))
        client.sendAudio(Data(repeating: 0, count: 2))
        DispatchQueue.global().async { socket.acknowledge() }
        await fulfillment(of: [enteredSend], timeout: 2)
        let readyWhileFlushing = await client.awaitSessionReady(timeout: 0.01)
        XCTAssertFalse(readyWhileFlushing)
        releaseSend.signal()
        let readyAfterFlush = await client.awaitSessionReady(timeout: 2)
        XCTAssertTrue(readyAfterFlush)
        await client.waitForPendingSends()
        client.commitInputBuffer()
        XCTAssertEqual(socket.types.suffix(2), ["input_audio_buffer.append", "input_audio_buffer.commit"])
        client.stop()
    }

    private func makeClient() -> (OpenAIRealtimeWebSocketClient, OverflowTestSocket) {
        let socket = OverflowTestSocket()
        let client = OpenAIRealtimeWebSocketClient(
            apiKey: "synthetic-test-key", model: "gpt-live-transcribe", language: nil, sampleRate: 24_000,
            makeSocket: { _ in socket }
        )
        return (client, socket)
    }
}

/// Tests deliver parsed provider events; they do not substitute another buffer implementation.
final class OverflowTestSocket: OpenAIRealtimeSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [[String: Any]] = []
    private var receiver: (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    private var running = false
    var beforeAudioSend: (@Sendable () -> Void)?

    var state: URLSessionTask.State { lock.withLock { running ? .running : .canceling } }
    var types: [String] { lock.withLock { messages.compactMap { $0["type"] as? String } } }
    var audio: [Data] {
        lock.withLock { messages.compactMap { ($0["audio"] as? String).flatMap { Data(base64Encoded: $0) } } }
    }
    func resume() { lock.withLock { running = true } }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock { running = false }
    }
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        if case .string(let text) = message,
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if object["type"] as? String == "input_audio_buffer.append" { beforeAudioSend?() }
            lock.withLock { messages.append(object) }
        }
        completionHandler(nil)
    }
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        lock.withLock { receiver = completionHandler }
    }
    func acknowledge() { emit(["type": "session.updated"]) }
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
        callback?(.success(.string(text)))
    }
}

private final class LockedOverflowCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
