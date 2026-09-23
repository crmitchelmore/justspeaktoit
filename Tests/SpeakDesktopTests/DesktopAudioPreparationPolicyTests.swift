import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopAudioPreparationPolicyTests: XCTestCase {
    func testOnlyCanonicalMetaAndAzureBatchRoutesRequirePreparedPCM() {
        let expected = AzureTranscriptionModels.batchIDs.union([MetaMuseVoiceTranscribe.batchCatalogID])
        let requiringPreparation = Set(DesktopTranscription.batchModels.filter {
            DesktopTranscription.requiresCanonicalPCM16WAV(model: $0.id)
        }.map(\.id))
        XCTAssertEqual(requiringPreparation, expected)
        for model in ModelCatalog.batchTranscription {
            XCTAssertEqual(DesktopTranscription.requiresCanonicalPCM16WAV(model: model.id), expected.contains(model.id))
        }
    }

    func testPreparationPolicyUsesCanonicalRoutingAndNormalisesWhitespace() {
        XCTAssertTrue(DesktopTranscription.requiresCanonicalPCM16WAV(
            model: "  \(MetaMuseVoiceTranscribe.batchCatalogID)\n"
        ))
        for model in ["azure/unknown", "meta/unknown", "apple/local/SFSpeechRecognizer", "__model_custom__"] {
            XCTAssertFalse(DesktopTranscription.requiresCanonicalPCM16WAV(model: model))
        }
    }
}
