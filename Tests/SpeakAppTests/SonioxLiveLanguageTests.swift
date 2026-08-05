import XCTest

@testable import SpeakApp

final class SonioxLiveLanguageTests: XCTestCase {
    func testInitialConfig_explicitLocaleAddsLanguageHint() {
        let payload = SonioxLiveTranscriber.initialConfigPayload(
            apiKey: "test-key",
            model: "stt-rt-v5",
            language: "fr_FR",
            sampleRate: 16_000
        )

        XCTAssertEqual(payload["language_hints"] as? [String], ["fr"])
    }

    func testInitialConfig_automaticOmitsLanguageHint() {
        let payload = SonioxLiveTranscriber.initialConfigPayload(
            apiKey: "test-key",
            model: "stt-rt-v5",
            language: nil,
            sampleRate: 16_000
        )

        XCTAssertNil(payload["language_hints"])
    }
}
