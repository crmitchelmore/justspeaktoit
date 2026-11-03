import SpeakCore
import XCTest
@testable import SpeakApp

final class OpenAITTSCatalogueParityTests: XCTestCase {
    func testMacCatalogue_PreservesCanonicalIdentifiersOrderNamesAndTraits() {
        let speechAPI = Array(VoiceCatalog.openaiVoices.prefix(OpenAITTSCatalog.voices.count))
        XCTAssertEqual(speechAPI.map(\.id), OpenAITTSCatalog.voices.map(\.providerVoiceID))
        XCTAssertEqual(speechAPI.map(\.name), OpenAITTSCatalog.voices.map(\.name))
        XCTAssertEqual(Array(VoiceCatalog.openaiVoices.dropFirst(speechAPI.count).map(\.id)),
                       OpenAIRealtimeSpeech.voices.map { OpenAIRealtimeSpeech.voiceIDPrefix + $0.id })
        for (mac, core) in zip(speechAPI, OpenAITTSCatalog.voices) {
            XCTAssertEqual(mac.traits.map(\.rawValue), core.traits.map(\.rawValue))
            XCTAssertEqual(mac.provider, .openai)
            XCTAssertNil(mac.previewURL)
        }
        XCTAssertEqual(TTSProvider.openai.apiKeyIdentifier, "openai.tts.apiKey")
    }

    func testMacQuality_DefaultAndAllMappingsAreCanonicalWithoutRewritingStoredValues() throws {
        XCTAssertEqual(TTSSettings().quality, .high)
        XCTAssertEqual(try OpenAITTSCatalog.model(forQualityIdentifier: TTSSettings().quality.rawValue),
                       OpenAITTSCatalog.defaultModel)
        XCTAssertEqual(try TTSQuality.allCases.map { try OpenAITTSCatalog.model(forQualityIdentifier: $0.rawValue) },
                       [.mini, .standard, .highDefinition])
    }
}
