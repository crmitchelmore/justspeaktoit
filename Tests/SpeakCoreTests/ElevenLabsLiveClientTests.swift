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
        let query = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(query.first { $0.name == "audio_format" }?.value, "pcm_16000")
        // The client owns manual commits of at most twenty seconds.
        XCTAssertEqual(query.first { $0.name == "commit_strategy" }?.value, "manual")
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
        XCTAssertEqual(
            payloads.map { $0["audio_base_64"] as? String },
            [Data([1, 2]), Data([3, 4])].map { $0.base64EncodedString() }
        )
    }

    /// The manual commit's `committed_transcript` completes the finish: each
    /// commit has exactly one, so a timestamped twin or a repeat arriving
    /// after it cannot add a second utterance.
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
        XCTAssertEqual(awaited4, "Yes.")
        let commit = try? json(textMessages(socket).last ?? "")
        XCTAssertEqual(commit?["commit"] as? Bool, true)
        XCTAssertEqual(commit?["audio_base_64"] as? String, "")
        let awaited5 = await client.finishAndWait()
        XCTAssertEqual(awaited5, "Yes.")
    }

    /// Each full twenty-second segment is committed while recording; a
    /// timestamped final that arrives alone still answers its commit.
    func testTimestampedFinalsCountWhenTheyArriveAlone() async {
        let socket = TestLiveWebSocket()
        let client = makeClient(socket, sampleRate: 8_000)
        let lock = NSLock()
        var finals: [String] = []
        client.start(onTranscript: { text, isFinal in
            if isFinal { lock.withLock { finals.append(text) } }
        }, onError: { _ in })
        socket.emit(#"{"message_type":"session_started"}"#)
        fillSegment(client)
        socket.emit(#"{"message_type":"committed_transcript_with_timestamps","text":"One."}"#)
        fillSegment(client)
        socket.emit(#"{"message_type":"committed_transcript_with_timestamps","text":"Two."}"#)
        let delivered = await eventually { lock.withLock { finals.count == 2 } }
        XCTAssertTrue(delivered)
        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "One. Two.")
        XCTAssertEqual(lock.withLock { finals }, ["One.", "Two."])
    }

    func testAudioCapturedBeforeStartIsReplayedAfterHandshake() async throws {
        let socket = TestLiveWebSocket()
        let client = makeClient(socket)
        client.sendAudio(Data([5, 6]))
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        socket.emit(#"{"message_type":"session_started"}"#)
        let replayed = await eventually { socket.messages.count == 1 }
        XCTAssertTrue(replayed)
        let payload = try json(try XCTUnwrap(textMessages(socket).first))
        XCTAssertEqual(payload["audio_base_64"] as? String, Data([5, 6]).base64EncodedString())
    }

    func testMissingHandshakeFailsAtStartupBoundWithoutFinish() async {
        let socket = TestLiveWebSocket()
        let client = ElevenLabsLiveClient(
            apiKey: "test-key",
            timing: .init(readiness: 0.15, postCommitDrain: 0.05, overall: 0.4, startup: 0.1),
            socketFactory: TestSocketFactory([socket]).make
        )
        let failed = expectation(description: "startup failure")
        client.start(onTranscript: { _, _ in }, onError: { error in
            if case ElevenLabsLiveError.connectionFailed = error { failed.fulfill() }
        })
        client.sendAudio(Data([1, 2]))
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(socket.cancelCount, 1)
        XCTAssertFalse(client.isConnected)
    }

    func testHeldSendAndConcurrentFinishersResolveAtBound() async {
        let socket = TestLiveWebSocket()
        socket.automaticallyCompletesSends = false
        let client = makeClient(socket, overall: 0.12)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        socket.emit(#"{"message_type":"session_started"}"#)
        client.sendAudio(Data([1, 2]))
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
        let client = makeClient(socket, sampleRate: 8_000)
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
        // A committed transcript answers the commit of a full segment.
        fillSegment(client)
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

    private func makeClient(
        _ socket: TestLiveWebSocket, overall: TimeInterval = 0.4, sampleRate: Int = 16_000
    ) -> ElevenLabsLiveClient {
        ElevenLabsLiveClient(
            apiKey: "test-key", sampleRate: sampleRate,
            timing: .init(readiness: 0.15, postCommitDrain: 0.5, overall: overall),
            socketFactory: TestSocketFactory([socket]).make
        )
    }

    /// Sends one full twenty-second segment at 8 kHz, which sends its commit.
    private func fillSegment(_ client: ElevenLabsLiveClient) {
        for _ in 0..<100 { client.sendAudio(Data(repeating: 0, count: 3_200)) }
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
