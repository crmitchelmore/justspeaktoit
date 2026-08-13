import XCTest
@testable import SpeakCore

final class SonioxTTSCatalogTests: XCTestCase {
    func testVoiceIdentifiers_AreUniqueAndProviderScoped() {
        let voices = SonioxTTSCatalog.voices

        XCTAssertEqual(Set(voices.map(\.id)).count, voices.count)
        XCTAssertEqual(Set(voices.map(\.providerVoiceID)).count, voices.count)
        XCTAssertTrue(voices.allSatisfy { $0.providerVoiceID == "soniox/\($0.id)" })
        XCTAssertTrue(voices.allSatisfy { $0.apiVoiceName == $0.id })
    }

    func testCatalogue_ExposesTheBuiltInVoicesAcrossEveryAccent() {
        let voices = SonioxTTSCatalog.voices

        XCTAssertEqual(voices.count, 28)
        for accent in [SonioxTTSVoiceAccent.american, .australian, .british, .indian, .spanish] {
            XCTAssertFalse(
                voices.filter { $0.accent == accent }.isEmpty,
                "Catalogue should offer at least one \(accent.rawValue) voice"
            )
        }
    }

    func testModels_ExposeCompatibleVoicesAndDefaults() {
        XCTAssertEqual(SonioxTTSCatalog.defaultModel.rawValue, "tts-rt-v2")

        for model in SonioxTTSCatalog.models {
            XCTAssertFalse(SonioxTTSCatalog.voices(for: model).isEmpty)
            XCTAssertTrue(
                SonioxTTSCatalog.voices(for: model)
                    .contains(SonioxTTSCatalog.defaultVoice(for: model))
            )
        }
    }

    func testRetiredModelIdentifiers_RollForwardToTheCurrentModel() {
        for legacyID in ["tts-rt-v1", "tts-rt-v1-preview", "TTS-RT-V1", " v1 "] {
            XCTAssertEqual(
                SonioxTTSCatalog.model(forLegacyID: legacyID),
                .realtimeV2,
                "\(legacyID) should resolve to the current model"
            )
        }
        XCTAssertNil(SonioxTTSCatalog.model(forLegacyID: "tts-rt-v99"))
    }

    func testVoiceLookup_AcceptsProviderPrefixAndAnyCasing() throws {
        let direct = try XCTUnwrap(SonioxTTSCatalog.voice(forID: "Adrian"))
        let prefixed = try XCTUnwrap(SonioxTTSCatalog.voice(forID: " soniox/adrian "))

        XCTAssertEqual(direct.id, "Adrian")
        XCTAssertEqual(prefixed, direct)
        XCTAssertNil(SonioxTTSCatalog.voice(forID: "soniox/not-a-voice"))
    }

    func testMissingOrUnknownSelection_ResolvesToCatalogueDefaults() {
        for voiceID in [nil, "", "   ", "soniox/retired-voice"] as [String?] {
            let selection = SonioxTTSCatalog.resolvedSelection(modelID: nil, voiceID: voiceID)

            XCTAssertEqual(selection.model, SonioxTTSCatalog.defaultModel)
            XCTAssertEqual(
                selection.voice,
                SonioxTTSCatalog.defaultVoice(for: SonioxTTSCatalog.defaultModel)
            )
        }
    }

    func testLanguageCode_ReducesLocalePreferencesAndDefaultsToEnglish() {
        XCTAssertEqual(SonioxTTSCatalog.languageCode(forLocaleIdentifier: "en_GB"), "en")
        XCTAssertEqual(SonioxTTSCatalog.languageCode(forLocaleIdentifier: "pt-BR"), "pt")
        XCTAssertEqual(SonioxTTSCatalog.languageCode(forLocaleIdentifier: "de"), "de")

        for identifier in [nil, "", "   ", "automatic"] as [String?] {
            XCTAssertEqual(SonioxTTSCatalog.languageCode(forLocaleIdentifier: identifier), "en")
        }
    }
}
