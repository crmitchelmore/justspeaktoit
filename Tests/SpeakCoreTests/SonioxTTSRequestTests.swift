import XCTest
@testable import SpeakCore

/// The request type owns Soniox's documented limits, so callers cannot build a
/// request the API will reject.
final class SonioxTTSRequestTests: XCTestCase {
    private let voice = SonioxTTSCatalog.defaultVoice(for: SonioxTTSCatalog.defaultModel)

    func testBody_CarriesTheCurrentModelAndVoiceName() throws {
        let body = SonioxTTSRequest(
            language: "en",
            voice: voice,
            audioFormat: .mp3,
            sampleRate: 24_000
        ).jsonBody(text: "Hello")

        XCTAssertEqual(body["model"] as? String, "tts-rt-v2")
        XCTAssertEqual(body["voice"] as? String, voice.apiVoiceName)
        XCTAssertEqual(body["language"] as? String, "en")
        XCTAssertEqual(body["audio_format"] as? String, "mp3")
        XCTAssertEqual(body["sample_rate"] as? Int, 24_000)
        XCTAssertEqual(body["text"] as? String, "Hello")
    }

    func testSpeed_IsClampedToTheAcceptedRange() {
        let tooSlow = SonioxTTSRequest(language: "en", voice: voice, audioFormat: .wav, speed: 0.1)
        let tooFast = SonioxTTSRequest(language: "en", voice: voice, audioFormat: .wav, speed: 3.0)

        XCTAssertEqual(tooSlow.speed, SonioxTTSAPI.speedRange.lowerBound)
        XCTAssertEqual(tooFast.speed, SonioxTTSAPI.speedRange.upperBound)
    }

    func testUnsupportedSampleRate_IsDroppedRatherThanSent() {
        let request = SonioxTTSRequest(
            language: "en",
            voice: voice,
            audioFormat: .aac,
            sampleRate: 12_345
        )

        XCTAssertNil(request.sampleRate)
        XCTAssertNil(request.jsonBody(text: "Hello")["sample_rate"])
    }

    func testOverlongText_FailsBeforeReachingTheNetwork() async {
        let request = SonioxTTSRequest(language: "en", voice: voice, audioFormat: .mp3)
        let text = String(repeating: "a", count: SonioxTTSAPI.maxTextLength + 1)

        do {
            _ = try await SonioxTTSAPI().synthesize(text: text, apiKey: "unused", request: request)
            XCTFail("Expected the request to be rejected locally")
        } catch let error as SonioxTTSAPIError {
            XCTAssertEqual(
                error,
                .textTooLong(limit: SonioxTTSAPI.maxTextLength, characterCount: text.count)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testErrorMessage_PrefersSonioxErrorPayload() {
        let payload = Data(#"{"error_message":"invalid voice","request_id":"abc"}"#.utf8)

        XCTAssertEqual(SonioxTTSAPI.errorMessage(from: payload), "invalid voice")
        XCTAssertEqual(SonioxTTSAPI.errorMessage(from: Data("boom".utf8)), "boom")
    }
}
