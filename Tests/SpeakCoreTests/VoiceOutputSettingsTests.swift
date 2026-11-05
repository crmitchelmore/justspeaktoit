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

    /// Azure neural and MAI voices are macOS-only for now (#1052): iOS playback has no Azure
    /// route, so the shared iOS provider list must not offer one or reuse the Azure credential.
    func testAzureVoiceOutput_IsNotAnIOSVoiceOutputProvider() {
        for provider in VoiceOutputProvider.allCases {
            XCTAssertFalse(provider.rawValue.lowercased().contains("azure"), provider.rawValue)
            XCTAssertNotEqual(provider.apiKeyIdentifier, "azure.speech.apiKey", provider.rawValue)
        }
        XCTAssertEqual(VoiceOutputProvider.allCases, [.deepgram, .soniox, .openrouter])
    }
}
