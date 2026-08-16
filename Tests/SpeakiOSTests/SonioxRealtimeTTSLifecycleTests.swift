#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// Failure reporting, keepalive and audio-route behaviour of one open stream.
@MainActor
final class SonioxRealtimeTTSLifecycleTests: XCTestCase {
    func testAbruptClose_afterProviderFailure_reportsClassifiedFailureNotSocketError() async throws {
        let connection = MockSonioxWebSocketConnection()
        connection.rewriteStreamID = true
        connection.responses = [eventData(#"""
        {
            "stream_id":"STREAM",
            "error_code":401,
            "error_type":"unauthenticated",
            "error_message":"Invalid API key",
            "request_id":"request-9"
        }
        """#)]
        connection.receiveFailure = URLError(.networkConnectionLost)
        let client = SonioxRealtimeTTSClient(
            webSocketFactory: MockSonioxWebSocketFactory(connections: [connection]),
            audioPlayer: MockSonioxPCMAudioPlayer()
        )

        do {
            try await client.speak(
                text: "Soniox rejects this key",
                apiKey: "credential",
                voice: "Maya",
                language: "en",
                region: .unitedStates,
                speed: 1
            )
            XCTFail("A rejected stream should not complete successfully")
        } catch let error as SonioxIOSVoiceOutputError {
            guard case .provider(let failure) = error else {
                return XCTFail("Expected the classified provider failure, observed \(error)")
            }
            XCTAssertEqual(failure.type, .unauthenticated)
            XCTAssertEqual(failure.statusCode, 401)
            XCTAssertEqual(failure.requestID, "request-9")
        }

        XCTAssertTrue(connection.didClose)
        XCTAssertFalse(client.isSpeaking)
    }

    func testAudioEndOnlyFrame_completesTheStreamWithoutSamples() async throws {
        let connection = MockSonioxWebSocketConnection()
        connection.rewriteStreamID = true
        connection.responses = [
            eventData(#"{"stream_id":"STREAM","audio_end":true}"#),
            eventData(#"{"stream_id":"STREAM","terminated":true}"#)
        ]
        let audio = MockSonioxPCMAudioPlayer()
        let client = SonioxRealtimeTTSClient(
            webSocketFactory: MockSonioxWebSocketFactory(connections: [connection]),
            audioPlayer: audio
        )

        try await client.speak(
            text: "Nothing to play",
            apiKey: "credential",
            voice: "Maya",
            language: "en",
            region: .unitedStates,
            speed: 1
        )

        XCTAssertEqual(audio.enqueued.map(\.data), [Data()])
        XCTAssertTrue(connection.didClose)
    }

    func testInterruptionEnd_resumesOnlyWhenTheSystemPermitsIt() async throws {
        let stream = try await startedStream()
        defer { stream.client.stop() }

        stream.client.handleAudioInterruption(type: .began, options: [])
        stream.client.handleAudioInterruption(type: .ended, options: [])
        XCTAssertTrue(stream.audio.resumedStreamIDs.isEmpty)

        stream.client.handleAudioInterruption(type: .ended, options: .shouldResume)

        XCTAssertEqual(stream.audio.pausedStreamIDs.count, 1)
        XCTAssertEqual(stream.audio.resumedStreamIDs.count, 1)
    }

    func testRouteChange_pausesWhenTheOutputDeviceDisappears() async throws {
        let stream = try await startedStream()
        defer { stream.client.stop() }

        stream.client.handleRouteChange(reason: .newDeviceAvailable)
        stream.client.handleRouteChange(reason: .oldDeviceUnavailable)

        XCTAssertEqual(stream.audio.resumedStreamIDs.count, 1)
        XCTAssertEqual(stream.audio.pausedStreamIDs.count, 1)
    }

    func testOpenStream_sendsConnectionScopedKeepAlive() async throws {
        let connection = MockSonioxWebSocketConnection()
        let client = SonioxRealtimeTTSClient(
            webSocketFactory: MockSonioxWebSocketFactory(connections: [connection]),
            audioPlayer: MockSonioxPCMAudioPlayer(),
            keepAliveInterval: .milliseconds(1)
        )
        let speaking = Task {
            try await client.speak(
                text: "Hold the socket open",
                apiKey: "credential",
                voice: "Maya",
                language: "en",
                region: .unitedStates,
                speed: 1
            )
        }
        for _ in 0..<500 where connection.sent.count < 3 {
            try await Task.sleep(for: .milliseconds(1))
        }

        let messages = try connection.sent.map(jsonObject)
        let keepAlive = try XCTUnwrap(messages.last { $0["keep_alive"] != nil })
        XCTAssertEqual(keepAlive["keep_alive"] as? Bool, true)
        XCTAssertNil(keepAlive["stream_id"])

        client.stop()
        speaking.cancel()
        _ = try? await speaking.value
    }

    private struct StartedStream {
        let client: SonioxRealtimeTTSClient
        let connection: MockSonioxWebSocketConnection
        let audio: MockSonioxPCMAudioPlayer
    }

    private func startedStream() async throws -> StartedStream {
        let connection = MockSonioxWebSocketConnection()
        let audio = MockSonioxPCMAudioPlayer()
        let client = SonioxRealtimeTTSClient(
            webSocketFactory: MockSonioxWebSocketFactory(connections: [connection]),
            audioPlayer: audio
        )
        Task {
            try await client.speak(
                text: "Keep the active route",
                apiKey: "credential",
                voice: "Maya",
                language: "en",
                region: .unitedStates,
                speed: 1
            )
        }
        try await waitForSentMessages(2, on: connection)
        return StartedStream(client: client, connection: connection, audio: audio)
    }
}
#endif
