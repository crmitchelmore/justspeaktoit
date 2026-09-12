import Foundation
import XCTest
@testable import SpeakCore

final class ElevenLabsLiveClientTests: XCTestCase {
    func testRequestAndAudioUseRealtimeProtocolWithExactPCM() async throws {
        let socket = TestLiveWebSocket()
        let factory = TestSocketFactory([socket])
        let client = ElevenLabsLiveClient(
            apiKey: "test-key", language: "en", sampleRate: 16_000,
            timing: .init(readiness: 0.2, postCommitDrain: 0.05, overall: 0.4),
            socketFactory: factory.make
        )
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        socket.emit(#"{"message_type":"session_started"}"#)
        let pcm = Data([0, 1, 127, 255])
        client.sendAudio(pcm)
        let condition1 = await eventually { socket.messages.count == 1 }
        XCTAssertTrue(condition1)

        let request = try XCTUnwrap(factory.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/speech-to-text/realtime")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "test-key")
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "audio_format" }?.value, "pcm_16000")
        XCTAssertEqual(query.first { $0.name == "commit_strategy" }?.value, "vad")
        XCTAssertFalse(socket.messages.contains { if case .data = $0 { return true }; return false })
        let object = try json(textMessages(socket)[0])
        XCTAssertEqual(object["audio_base_64"] as? String, pcm.base64EncodedString())
        XCTAssertEqual(object["sample_rate"] as? Int, 16_000)
    }

    func testHandshakeAutomaticallyReplaysPrerollInOrder() async throws {
        let socket = TestLiveWebSocket()
        let client = makeClient(socket)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        client.sendAudio(Data([1, 2]))
        client.sendAudio(Data([3, 4]))
        socket.emit(#"{"message_type":"session_started"}"#)
        let condition2 = await eventually { socket.messages.count == 2 }
        XCTAssertTrue(condition2)
        let payloads = try textMessages(socket).map(json)
        XCTAssertEqual(payloads.map { $0["audio_base_64"] as? String }, [Data([1, 2]), Data([3, 4])].map { $0.base64EncodedString() })
    }

    func testFinishBeforeHandshakeReplaysThenCommitsAndRetainsLateFinals() async {
        let socket = TestLiveWebSocket()
        let client = makeClient(socket)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        client.sendAudio(Data([9, 8]))
        async let result = client.finishAndWait()
        socket.emit(#"{"message_type":"session_started"}"#)
        let condition3 = await eventually { socket.messages.count == 2 }
        XCTAssertTrue(condition3)
        socket.emit(#"{"message_type":"committed_transcript","text":"Yes."}"#)
        socket.emit(#"{"message_type":"committed_transcript_with_timestamps","text":"Yes."}"#)
        socket.emit(#"{"message_type":"committed_transcript","text":"Yes."}"#)
        let awaited4 = await result
        XCTAssertEqual(awaited4, "Yes. Yes.")
        let commit = try? json(textMessages(socket).last ?? "")
        XCTAssertEqual(commit?["commit"] as? Bool, true)
        XCTAssertEqual(commit?["audio_base_64"] as? String, "")
        let awaited5 = await client.finishAndWait()
        XCTAssertEqual(awaited5, "Yes. Yes.")
    }

    func testHeldSendAndConcurrentFinishersResolveAtBound() async {
        let socket = TestLiveWebSocket()
        socket.automaticallyCompletesSends = false
        let client = makeClient(socket, overall: 0.12)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        socket.emit(#"{"message_type":"session_started"}"#)
        client.sendAudio(Data([1]))
        async let one = client.finishAndWait()
        async let two = client.finishAndWait()
        let awaited6 = await one
        XCTAssertNil(awaited6)
        let awaited7 = await two
        XCTAssertNil(awaited7)
        XCTAssertEqual(socket.cancelCount, 1)
    }

    func testTerminalErrorDeliveredOnceAndCallbackCanQueryConnection() async {
        let socket = TestLiveWebSocket()
        let client = makeClient(socket)
        let error = expectation(description: "error")
        error.expectedFulfillmentCount = 1
        client.start(onTranscript: { _, _ in }, onError: { _ in
            _ = client.isConnected
            error.fulfill()
        })
        socket.emit(#"{"message_type":"auth_error","error":"401 unauthorized"}"#)
        await fulfillment(of: [error], timeout: 1)
        XCTAssertEqual(socket.cancelCount, 1)
    }

    func testRateLimitIsTerminalAndCallbacksStayOrdered() async {
        let socket = TestLiveWebSocket()
        let client = makeClient(socket)
        let delivered = expectation(description: "ordered callbacks")
        delivered.expectedFulfillmentCount = 3
        let lock = NSLock()
        var events: [String] = []
        client.start(onTranscript: { text, isFinal in
            lock.withLock { events.append("\(isFinal):\(text)") }
            delivered.fulfill()
        }, onError: { _ in
            lock.withLock { events.append("error") }
            delivered.fulfill()
        })
        socket.emit(#"{"message_type":"session_started"}"#)
        socket.emit(#"{"message_type":"partial_transcript","text":"Hel"}"#)
        socket.emit(#"{"message_type":"committed_transcript","text":"Hello"}"#)
        socket.emit(#"{"message_type":"rate_limited","error":"rate limited"}"#)
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(lock.withLock { events }, ["false:Hel", "true:Hello", "error"])
    }

    func testStopStillCancelsWhenCallerDropsLastClientReference() async {
        let socket = TestLiveWebSocket()
        weak var released: ElevenLabsLiveClient?
        do {
            var client: ElevenLabsLiveClient? = makeClient(socket)
            released = client
            client?.start(onTranscript: { _, _ in }, onError: { _ in })
            let condition8 = await eventually { socket.state == .running }
            XCTAssertTrue(condition8)
            client?.stop()
            client = nil
        }
        let condition9 = await eventually { socket.cancelCount > 0 }
        XCTAssertTrue(condition9)
        let condition10 = await eventually { released == nil }
        XCTAssertTrue(condition10)
    }

    private func makeClient(_ socket: TestLiveWebSocket, overall: TimeInterval = 0.4) -> ElevenLabsLiveClient {
        ElevenLabsLiveClient(
            apiKey: "test-key",
            timing: .init(readiness: 0.15, postCommitDrain: 0.05, overall: overall),
            socketFactory: TestSocketFactory([socket]).make
        )
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
