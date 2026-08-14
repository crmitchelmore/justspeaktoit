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

    func testProviderCredentialsAndSpeedBounds_AreExplicit() {
        XCTAssertEqual(VoiceOutputProvider.deepgram.apiKeyIdentifier, "deepgram.apiKey")
        XCTAssertEqual(VoiceOutputProvider.soniox.apiKeyIdentifier, "soniox.apiKey")
        XCTAssertEqual(VoiceOutputProvider.soniox.speedRange, 0.7...1.3)
    }
}
