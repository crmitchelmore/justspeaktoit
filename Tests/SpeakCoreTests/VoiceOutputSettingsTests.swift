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

    /// Product decision (#1052): Azure MAI-Voice speech generation is macOS-only.
    /// `VoiceOutputProvider` is the iOS voice-output projection, so it must not
    /// offer Azure or route a saved MAI voice to an Azure client.
    func testAzureMAIVoiceGeneration_IsNotOfferedOnIOS() throws {
        XCTAssertFalse(VoiceOutputProvider.allCases.contains {
            $0.rawValue.localizedCaseInsensitiveContains("azure")
                || $0.apiKeyIdentifier == AzureSpeechConfiguration.credentialIdentifier
        })
        let maiVoice = try XCTUnwrap(AzureMAIVoiceCatalog.voices.first)
        for model in AzureMAIVoiceModel.allCases {
            let provider = VoiceOutputProvider.inferred(modelID: model.rawValue, voiceID: maiVoice.id)
            XCTAssertNotEqual(provider.apiKeyIdentifier, AzureSpeechConfiguration.credentialIdentifier)
        }
    }
}
