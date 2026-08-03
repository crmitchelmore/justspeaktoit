import XCTest
@testable import SpeakCore

final class DeepgramTTSCatalogTests: XCTestCase {
    func testVoiceIdentifiers_AreUniqueAndProviderScoped() {
        let voices = DeepgramTTSCatalog.voices

        XCTAssertEqual(Set(voices.map(\.id)).count, voices.count)
        XCTAssertEqual(Set(voices.map(\.providerVoiceID)).count, voices.count)
        XCTAssertTrue(voices.allSatisfy { $0.providerVoiceID == "deepgram/\($0.id)" })
    }

    func testModels_ExposeCompatibleVoicesAndDefaults() {
        for model in DeepgramTTSCatalog.models {
            let voices = DeepgramTTSCatalog.voices(for: model)
            XCTAssertFalse(voices.isEmpty)
            XCTAssertTrue(voices.allSatisfy { $0.model == model })
            XCTAssertEqual(DeepgramTTSCatalog.defaultVoice(for: model).model, model)
        }
    }

    func testAura2Catalogue_ContainsCurrentEnglishAndLegacySharedVoices() {
        let aura2IDs = Set(DeepgramTTSCatalog.voices(for: .aura2).map(\.id))

        XCTAssertEqual(aura2IDs.count, 41)
        XCTAssertEqual(DeepgramTTSCatalog.voices(for: .aura1).count, 12)
        XCTAssertTrue(aura2IDs.contains("aura-2-thalia-en"))
        XCTAssertTrue(aura2IDs.contains("aura-2-amalthea-en"))
        XCTAssertTrue(aura2IDs.contains("aura-2-hyperion-en"))
        XCTAssertTrue(aura2IDs.contains("aura-2-zeus-en"))
    }

    func testLegacyShortVoice_MigratesWithinSelectedModel() {
        let aura2 = DeepgramTTSCatalog.resolvedSelection(
            modelID: "aura-2",
            voiceID: "asteria"
        )
        let aura1 = DeepgramTTSCatalog.resolvedSelection(
            modelID: "aura-1",
            voiceID: "athena"
        )

        XCTAssertEqual(aura2.model, .aura2)
        XCTAssertEqual(aura2.voice.id, "aura-2-asteria-en")
        XCTAssertEqual(aura1.model, .aura1)
        XCTAssertEqual(aura1.voice.id, "aura-athena-en")
    }

    func testProviderPrefixedVoice_InfersModelWhenLegacyModelIsMissing() {
        let selection = DeepgramTTSCatalog.resolvedSelection(
            modelID: nil,
            voiceID: "deepgram/aura-zeus-en"
        )

        XCTAssertEqual(selection.model, .aura1)
        XCTAssertEqual(selection.voice.id, "aura-zeus-en")
    }

    func testMissingOrBlankSelection_ResolvesToCatalogueDefaults() {
        for voiceID in [nil, "", "   "] as [String?] {
            let selection = DeepgramTTSCatalog.resolvedSelection(
                modelID: nil,
                voiceID: voiceID
            )

            XCTAssertEqual(selection.model, DeepgramTTSCatalog.defaultModel)
            XCTAssertEqual(
                selection.voice,
                DeepgramTTSCatalog.defaultVoice(for: DeepgramTTSCatalog.defaultModel)
            )
        }
    }

    func testIncompatibleVoice_MigratesByNameThenFallsBackSafely() {
        let migratedByName = DeepgramTTSCatalog.resolvedSelection(
            modelID: "aura-2",
            voiceID: "deepgram/aura-luna-en"
        )
        let fallback = DeepgramTTSCatalog.resolvedSelection(
            modelID: "aura",
            voiceID: "retired-voice"
        )

        XCTAssertEqual(migratedByName.voice.id, "aura-2-luna-en")
        XCTAssertEqual(fallback.voice, DeepgramTTSCatalog.defaultVoice(for: .aura1))
    }
}
