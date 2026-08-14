import Foundation
import XCTest

@testable import SpeakCore

final class SonioxTTSRealtimeTests: XCTestCase {
    func testConfiguration_encodesAuthenticationRegionIndependentContractAndBoundedSpeed() throws {
        let config = SonioxTTSRealtimeConfiguration(
            apiKey: "credential",
            streamID: "stream-42",
            language: "EN-gb",
            voice: "Maya",
            speed: 9
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
        )

        XCTAssertEqual(object["api_key"] as? String, "credential")
        XCTAssertEqual(object["stream_id"] as? String, "stream-42")
        XCTAssertEqual(object["model"] as? String, "tts-rt-v2")
        XCTAssertEqual(object["language"] as? String, "en")
        XCTAssertEqual(object["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(object["sample_rate"] as? Int, 24_000)
        XCTAssertEqual(object["speed"] as? Double, SonioxTTSAPI.speedRange.upperBound)
    }

    func testTextAndCancelMessages_keepStreamIDAndOrderingFields() throws {
        let encoder = JSONEncoder()
        let text = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(
            SonioxTTSRealtimeText(text: "Hello", textEnd: true, streamID: "one")
        )) as? [String: Any])
        let cancel = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(
            SonioxTTSRealtimeCancel(streamID: "two")
        )) as? [String: Any])

        XCTAssertEqual(text["text"] as? String, "Hello")
        XCTAssertEqual(text["text_end"] as? Bool, true)
        XCTAssertEqual(text["stream_id"] as? String, "one")
        XCTAssertEqual(cancel["cancel"] as? Bool, true)
        XCTAssertEqual(cancel["stream_id"] as? String, "two")
        XCTAssertNil(cancel["text"])
    }

    func testNormalLifecycle_requiresAudioEndBeforeTerminated() throws {
        var lifecycle = SonioxTTSRealtimeLifecycle()
        lifecycle.recordTextEnd()
        XCTAssertThrowsError(try lifecycle.record(.terminated(streamID: "one")))
        try lifecycle.record(.audio(streamID: "one", data: Data(), isFinal: true))
        try lifecycle.record(.terminated(streamID: "one"))
        XCTAssertTrue(lifecycle.isTerminated)
    }

    func testCancelledLifecycle_acceptsTerminatedWithoutAudio() throws {
        var lifecycle = SonioxTTSRealtimeLifecycle()
        lifecycle.recordCancel()
        try lifecycle.record(.terminated(streamID: "one"))
        XCTAssertTrue(lifecycle.isTerminated)
    }

    func testFailedLifecycle_acceptsProviderErrorThenTerminatedWithoutAudio() throws {
        var lifecycle = SonioxTTSRealtimeLifecycle()
        lifecycle.recordTextEnd()
        try lifecycle.record(.failure(
            streamID: "one",
            failure: SonioxTTSFailure(
                statusCode: 429,
                type: .rateLimited,
                message: "Retry",
                requestID: "request-7"
            )
        ))
        try lifecycle.record(.terminated(streamID: "one"))
        XCTAssertTrue(lifecycle.isTerminated)
    }

    func testResponse_decodesAudioEndAndPrivacySafeFailureFields() throws {
        let audio = try JSONDecoder().decode(
            SonioxTTSRealtimeEvent.self,
            from: Data(#"{"stream_id":"one","audio":"AQI=","audio_end":true}"#.utf8)
        )
        let failure = try JSONDecoder().decode(
            SonioxTTSRealtimeEvent.self,
            from: Data(#"""
            {
                "stream_id":"one",
                "error_code":429,
                "error_type":"rate_limited",
                "error_message":"Retry",
                "request_id":"request-7"
            }
            """#.utf8)
        )

        XCTAssertEqual(audio, .audio(streamID: "one", data: Data([1, 2]), isFinal: true))
        XCTAssertEqual(
            failure,
            .failure(
                streamID: "one",
                failure: SonioxTTSFailure(
                    statusCode: 429,
                    type: .rateLimited,
                    message: "Retry",
                    requestID: "request-7"
                )
            )
        )
    }

    func testResponse_rejectsInvalidBase64Audio() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            SonioxTTSRealtimeEvent.self,
            from: Data(#"{"stream_id":"one","audio":"%%%"}"#.utf8)
        ))
    }

    func testChunker_preservesTextWithinProviderLimit() {
        let chunks = SonioxTTSRealtimeTextChunker.chunks(
            "One short sentence followed by another sentence",
            maximumCharacters: 12
        )

        XCTAssertTrue(chunks.allSatisfy { $0.count <= 12 })
        XCTAssertEqual(chunks.joined(), "One short sentence followed by another sentence")
    }

    func testChunker_returnsNoChunksForWhitespaceOnlyText() {
        XCTAssertTrue(SonioxTTSRealtimeTextChunker.chunks("   \n ").isEmpty)
    }

    func testLifecycle_rejectsAudioAfterTermination() throws {
        var lifecycle = SonioxTTSRealtimeLifecycle()
        lifecycle.recordCancel()
        try lifecycle.record(.terminated(streamID: "one"))

        XCTAssertThrowsError(try lifecycle.record(.audio(streamID: "one", data: Data(), isFinal: false))) {
            XCTAssertEqual($0 as? SonioxTTSRealtimeProtocolError, .eventAfterTermination)
        }
    }

    func testRegions_exposeMatchingRealtimeEndpoints() {
        XCTAssertEqual(SonioxTTSRegion.unitedStates.webSocketEndpoint.host, "tts-rt.soniox.com")
        XCTAssertEqual(SonioxTTSRegion.europe.webSocketEndpoint.host, "tts-rt.eu.soniox.com")
        XCTAssertEqual(SonioxTTSRegion.japan.webSocketEndpoint.host, "tts-rt.jp.soniox.com")
    }
}
