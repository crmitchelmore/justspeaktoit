import SpeakCore
import XCTest
@testable import SpeakApp

final class OpenAITTSCatalogueParityTests: XCTestCase {
    func testMacCatalogue_PreservesCanonicalIdentifiersOrderNamesAndTraits() {
        XCTAssertEqual(VoiceCatalog.openaiVoices.map(\.id), OpenAITTSCatalog.voices.map(\.providerVoiceID))
        XCTAssertEqual(VoiceCatalog.openaiVoices.map(\.name), OpenAITTSCatalog.voices.map(\.name))
        for (mac, core) in zip(VoiceCatalog.openaiVoices, OpenAITTSCatalog.voices) {
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
