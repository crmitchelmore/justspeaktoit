import XCTest
@testable import SpeakCore

final class VoiceOutputSettingsTests: XCTestCase {
    func testProviderInference_MigratesLegacyDeepgramAndSonioxSelections() {
        XCTAssertEqual(
            VoiceOutputProvider.inferred(modelID: "aura-2", voiceID: "aura-2-asteria-en"),
            .deepgram
        )
        XCTAssertEqual(
            VoiceOutputProvider.inferred(modelID: "tts-rt-v2", voiceID: "soniox/Maya"),
            .soniox
        )
    }

    func testOpenRouterSelectionInfersProviderWithoutFallingBack() {
        let identifier = OpenRouterSpeechSelection(modelID: "example/speech", voice: "voice-a").id
        XCTAssertEqual(VoiceOutputProvider.inferred(modelID: identifier, voiceID: "voice-a"), .openrouter)
        XCTAssertEqual(VoiceOutputProvider.inferred(modelID: "openrouter/speech/retired", voiceID: nil), .openrouter)
    }

    func testProviderCredentialsAndSpeedBounds_AreExplicit() {
        XCTAssertEqual(VoiceOutputProvider.deepgram.apiKeyIdentifier, "deepgram.apiKey")
        XCTAssertEqual(VoiceOutputProvider.soniox.apiKeyIdentifier, "soniox.apiKey")
        XCTAssertEqual(VoiceOutputProvider.openrouter.apiKeyIdentifier, "openrouter.apiKey")
        XCTAssertEqual(VoiceOutputProvider.soniox.speedRange, 0.7...1.3)
    }
}
