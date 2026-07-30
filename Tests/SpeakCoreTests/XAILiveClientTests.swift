import XCTest

@testable import SpeakCore

final class XAILiveClientTests: XCTestCase {
    func testWebSocketURL_pinsThinkFast2Model() throws {
        let url = try XCTUnwrap(XAILiveClient.webSocketURL(model: XAIVoiceModels.thinkFast2APIName))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.x.ai")
        XCTAssertEqual(components.path, "/v1/realtime")
        XCTAssertEqual(components.queryItems?.first?.value, XAIVoiceModels.thinkFast2APIName)
    }

    func testSessionUpdate_usesManualTranscriptionOnlyMode() throws {
        let json = try XCTUnwrap(XAILiveClient.sessionUpdateJSON(sampleRate: 24_000, language: "en_GB"))
        let data = try XCTUnwrap(json.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try XCTUnwrap(root["session"] as? [String: Any])
        let reasoning = try XCTUnwrap(session["reasoning"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])

        XCTAssertTrue(session["turn_detection"] is NSNull)
        XCTAssertEqual(reasoning["effort"] as? String, "none")
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)
        XCTAssertEqual(transcription["model"] as? String, XAIVoiceModels.inputTranscriptionAPIName)
        XCTAssertEqual(transcription["language_hint"] as? String, "en-GB")
        XCTAssertNil(root["response"])
    }

    func testTranscriptEvents_distinguishCumulativeUpdateAndFinal() throws {
        let update = try XCTUnwrap(XAILiveClient.transcriptEvent(from: """
        {
          "type": "conversation.item.input_audio_transcription.updated",
          "transcript": "Hello wor"
        }
        """))
        let final = try XCTUnwrap(XAILiveClient.transcriptEvent(from: """
        {
          "type": "conversation.item.input_audio_transcription.completed",
          "transcript": "Hello world."
        }
        """))

        XCTAssertEqual(update.text, "Hello wor")
        XCTAssertFalse(update.isFinal)
        XCTAssertEqual(final.text, "Hello world.")
        XCTAssertTrue(final.isFinal)
    }

    func testCatalogueAndRoute_exposeXAIOnBothPlatforms() throws {
        let option = try XCTUnwrap(ModelCatalog.liveTranscription.first {
            $0.id == XAIVoiceModels.thinkFast2CatalogID
        })
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: option.id))

        XCTAssertEqual(route.provider, .xai)
        XCTAssertEqual(route.apiModelName, XAIVoiceModels.thinkFast2APIName)
        XCTAssertEqual(route.sampleRate, 24_000)
        XCTAssertEqual(route.apiKeyIdentifier, "xai.apiKey")
        XCTAssertTrue(route.isSupportedOnIOS)
        XCTAssertNotNil(LiveTranscriptionClientFactory.makeClient(
            for: route,
            apiKey: "test-key",
            language: "en-GB"
        ))
    }
}
