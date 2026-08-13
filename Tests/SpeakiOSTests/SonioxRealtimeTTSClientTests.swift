#if os(iOS)
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

@MainActor
final class SonioxRealtimeTTSClientTests: XCTestCase {
    func testStream_sendsRegionConfigIncrementalTextAndFinalHandshake() async throws {
        let connection = MockSonioxWebSocketConnection()
        let factory = MockSonioxWebSocketFactory(connections: [connection])
        let audio = MockSonioxPCMAudioPlayer()
        let client = SonioxRealtimeTTSClient(webSocketFactory: factory, audioPlayer: audio)
        let text = String(repeating: "word ", count: 80).trimmingCharacters(in: .whitespaces)
        connection.responses = [
            eventData(#"{"stream_id":"STREAM","audio":"AAA=","audio_end":true}"#),
            eventData(#"{"stream_id":"STREAM","terminated":true}"#)
        ]
        connection.rewriteStreamID = true

        try await client.speak(
            text: text,
            apiKey: "credential",
            voice: "Maya",
            language: "en",
            region: .europe,
            speed: 1.2
        )

        XCTAssertEqual(factory.endpoints, [SonioxTTSRegion.europe.webSocketEndpoint])
        XCTAssertTrue(connection.didResume)
        XCTAssertTrue(connection.didClose)
        XCTAssertGreaterThan(connection.sent.count, 2)
        let messages = try connection.sent.map(jsonObject)
        let streamIDs = Set(messages.compactMap { $0["stream_id"] as? String })
        XCTAssertEqual(streamIDs.count, 1)
        XCTAssertEqual(messages.first?["api_key"] as? String, "credential")
        XCTAssertEqual(messages.first?["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(messages.last?["text_end"] as? Bool, true)
        XCTAssertEqual(messages.dropFirst().compactMap { $0["text"] as? String }.joined(), text)
        XCTAssertEqual(audio.enqueued.count, 1)
        XCTAssertNotNil(client.firstAudioLatencySeconds)
    }

    func testStop_sendsCancelAfterTextAndBoundsConnectionLifetime() async throws {
        let connection = MockSonioxWebSocketConnection()
        let factory = MockSonioxWebSocketFactory(connections: [connection])
        let audio = MockSonioxPCMAudioPlayer()
        let client = SonioxRealtimeTTSClient(webSocketFactory: factory, audioPlayer: audio)
        let speaking = Task {
            try await client.speak(
                text: "Cancel this response",
                apiKey: "credential",
                voice: "Maya",
                language: "en",
                region: .unitedStates,
                speed: 1
            )
        }
        await waitForSentMessages(2, on: connection)
        let streamID = try XCTUnwrap(jsonObject(connection.sent[0])["stream_id"] as? String)

        client.stop()
        await waitForSentMessages(3, on: connection)
        connection.push(eventData("{\"stream_id\":\"\(streamID)\",\"terminated\":true}"))
        do {
            try await speaking.value
            XCTFail("Cancelled stream should not complete successfully")
        } catch is CancellationError {
            // Expected.
        }

        let messages = try connection.sent.map(jsonObject)
        XCTAssertEqual(messages[1]["text_end"] as? Bool, true)
        XCTAssertEqual(messages[2]["cancel"] as? Bool, true)
        XCTAssertEqual(messages[2]["stream_id"] as? String, streamID)
        XCTAssertEqual(audio.stoppedStreamIDs.compactMap { $0 }.last, streamID)
    }

    func testStop_closesConnectionWhenCancelSendDoesNotComplete() async throws {
        let connection = MockSonioxWebSocketConnection()
        connection.blocksCancelSend = true
        let client = SonioxRealtimeTTSClient(
            webSocketFactory: MockSonioxWebSocketFactory(connections: [connection]),
            audioPlayer: MockSonioxPCMAudioPlayer(),
            cancelGracePeriod: .milliseconds(1)
        )
        let speaking = Task {
            try await client.speak(
                text: "Cancel this response",
                apiKey: "credential",
                voice: "Maya",
                language: "en",
                region: .unitedStates,
                speed: 1
            )
        }
        await waitForSentMessages(2, on: connection)

        client.stop()
        for _ in 0..<100 where !connection.didClose {
            try await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertTrue(connection.didClose)
        do {
            try await speaking.value
            XCTFail("Cancelled stream should not complete successfully")
        } catch is CancellationError {
            // Expected.
        }
    }

    // swiftlint:disable:next function_body_length
    func testReplacementStream_ignoresLateAudioFromCancelledStream() async throws {
        let first = MockSonioxWebSocketConnection()
        let second = MockSonioxWebSocketConnection()
        let factory = MockSonioxWebSocketFactory(connections: [first, second])
        let audio = MockSonioxPCMAudioPlayer()
        let client = SonioxRealtimeTTSClient(webSocketFactory: factory, audioPlayer: audio)
        let firstTask = Task {
            try await client.speak(
                text: "First",
                apiKey: "credential",
                voice: "Maya",
                language: "en",
                region: .unitedStates,
                speed: 1
            )
        }
        await waitForSentMessages(2, on: first)
        let firstID = try XCTUnwrap(jsonObject(first.sent[0])["stream_id"] as? String)

        let secondTask = Task {
            try await client.speak(
                text: "Second",
                apiKey: "credential",
                voice: "Maya",
                language: "en",
                region: .japan,
                speed: 1
            )
        }
        await waitForSentMessages(2, on: second)
        let secondID = try XCTUnwrap(jsonObject(second.sent[0])["stream_id"] as? String)
        first.push(eventData("{\"stream_id\":\"\(firstID)\",\"audio\":\"AAA=\",\"audio_end\":true}"))
        first.push(eventData("{\"stream_id\":\"\(firstID)\",\"terminated\":true}"))
        second.push(eventData("{\"stream_id\":\"\(secondID)\",\"audio\":\"AQI=\",\"audio_end\":true}"))
        second.push(eventData("{\"stream_id\":\"\(secondID)\",\"terminated\":true}"))

        do {
            try await firstTask.value
            XCTFail("Replaced stream should be cancelled")
        } catch is CancellationError {
            // Expected.
        }
        try await secondTask.value
        XCTAssertEqual(factory.endpoints.last, SonioxTTSRegion.japan.webSocketEndpoint)
        XCTAssertEqual(audio.enqueued.map(\.streamID), [secondID])
    }

    func testActiveStream_pausesForInterruptionAndResumesForRouteOrLifecycleChanges() async throws {
        let connection = MockSonioxWebSocketConnection()
        let audio = MockSonioxPCMAudioPlayer()
        let client = SonioxRealtimeTTSClient(
            webSocketFactory: MockSonioxWebSocketFactory(connections: [connection]),
            audioPlayer: audio
        )
        let speaking = Task {
            try await client.speak(
                text: "Keep the active route",
                apiKey: "credential",
                voice: "Maya",
                language: "en",
                region: .unitedStates,
                speed: 1
            )
        }
        await waitForSentMessages(2, on: connection)
        let streamID = try XCTUnwrap(jsonObject(connection.sent[0])["stream_id"] as? String)

        client.handleAudioInterruption(began: true)
        client.handleAudioInterruption(began: false)
        client.handleAudioLifecycleResume()
        connection.push(eventData("{\"stream_id\":\"\(streamID)\",\"audio\":\"AQI=\",\"audio_end\":true}"))
        connection.push(eventData("{\"stream_id\":\"\(streamID)\",\"terminated\":true}"))
        try await speaking.value

        XCTAssertEqual(audio.pausedStreamIDs, [streamID])
        XCTAssertEqual(audio.resumedStreamIDs, [streamID, streamID])
    }

    private func eventData(_ json: String) -> Data { Data(json.utf8) }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func waitForSentMessages(_ count: Int, on connection: MockSonioxWebSocketConnection) async {
        for _ in 0..<100 where connection.sent.count < count {
            await Task.yield()
        }
    }
}

@MainActor
private final class MockSonioxWebSocketFactory: SonioxTTSWebSocketFactory {
    private var connections: [MockSonioxWebSocketConnection]
    private(set) var endpoints: [URL] = []

    init(connections: [MockSonioxWebSocketConnection]) {
        self.connections = connections
    }

    func makeConnection(to endpoint: URL) -> SonioxTTSWebSocketConnection {
        endpoints.append(endpoint)
        return connections.removeFirst()
    }
}

@MainActor
private final class MockSonioxWebSocketConnection: SonioxTTSWebSocketConnection {
    var sent: [Data] = []
    var responses: [Data] = []
    var rewriteStreamID = false
    var blocksCancelSend = false
    private var receiveContinuation: CheckedContinuation<Data, Error>?
    private var sendContinuation: CheckedContinuation<Void, Error>?
    private(set) var didResume = false
    private(set) var didClose = false

    func resume() { didResume = true }

    func send(_ data: Data) async throws {
        sent.append(data)
        guard !didClose else { throw CancellationError() }
        guard blocksCancelSend,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["cancel"] as? Bool == true else { return }
        try await withCheckedThrowingContinuation { continuation in
            self.sendContinuation = continuation
        }
    }

    func receive() async throws -> Data {
        if !responses.isEmpty {
            return responseWithCurrentStreamID(responses.removeFirst())
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.receiveContinuation = continuation
        }
    }

    func close() {
        didClose = true
        sendContinuation?.resume(throwing: CancellationError())
        sendContinuation = nil
        receiveContinuation?.resume(throwing: CancellationError())
        receiveContinuation = nil
    }

    func push(_ data: Data) {
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(returning: responseWithCurrentStreamID(data))
        } else {
            responses.append(data)
        }
    }

    private func responseWithCurrentStreamID(_ data: Data) -> Data {
        guard rewriteStreamID,
              let first = sent.first,
              let object = try? JSONSerialization.jsonObject(with: first) as? [String: Any],
              let streamID = object["stream_id"] as? String,
              let string = String(data: data, encoding: .utf8) else { return data }
        return Data(string.replacingOccurrences(of: "STREAM", with: streamID).utf8)
    }
}

@MainActor
private final class MockSonioxPCMAudioPlayer: SonioxPCMAudioPlaying {
    private(set) var preparedStreamIDs: [String] = []
    private(set) var enqueued: [(data: Data, streamID: String)] = []
    private(set) var stoppedStreamIDs: [String?] = []
    private(set) var pausedStreamIDs: [String] = []
    private(set) var resumedStreamIDs: [String] = []

    func prepare(streamID: String) throws { preparedStreamIDs.append(streamID) }
    func enqueue(_ data: Data, streamID: String) throws { enqueued.append((data, streamID)) }
    func waitUntilDrained(streamID: String) async {}
    func pause(streamID: String) { pausedStreamIDs.append(streamID) }
    func resume(streamID: String) { resumedStreamIDs.append(streamID) }
    func stop(streamID: String?) { stoppedStreamIDs.append(streamID) }
}
#endif
