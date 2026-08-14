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

    func testLanguageCode_ReducesExplicitLocalePreferences() {
        XCTAssertEqual(SonioxTTSCatalog.languageCode(forLocaleIdentifier: "en_GB"), "en")
        XCTAssertEqual(SonioxTTSCatalog.languageCode(forLocaleIdentifier: "pt-BR"), "pt")
        XCTAssertEqual(SonioxTTSCatalog.languageCode(forLocaleIdentifier: "de"), "de")
    }

    func testAutomaticLanguage_PrefersContentThenDeviceLocale() {
        XCTAssertEqual(
            VoiceOutputLanguageCatalog.automaticLanguageCode(
                contentLanguageCode: "es-MX",
                deviceLocaleIdentifier: "ja_JP"
            ),
            "es"
        )
        XCTAssertEqual(
            VoiceOutputLanguageCatalog.automaticLanguageCode(
                contentLanguageCode: nil,
                deviceLocaleIdentifier: "ja_JP"
            ),
            "ja"
        )
    }

    func testRegions_ProvideMatchingValidationRESTAndWebSocketHosts() {
        let expectedHosts: [SonioxTTSRegion: (String, String)] = [
            .unitedStates: ("api.soniox.com", "tts-rt.soniox.com"),
            .europe: ("api.eu.soniox.com", "tts-rt.eu.soniox.com"),
            .japan: ("api.jp.soniox.com", "tts-rt.jp.soniox.com")
        ]

        for (region, hosts) in expectedHosts {
            XCTAssertEqual(region.modelsEndpoint.host, hosts.0)
            XCTAssertEqual(region.voicesEndpoint.host, hosts.0)
            XCTAssertEqual(region.speakEndpoint.host, hosts.1)
            XCTAssertEqual(region.webSocketEndpoint.host, hosts.1)
            XCTAssertEqual(region.webSocketEndpoint.scheme, "wss")
        }
    }

    func testRegionMigration_DefaultsLegacyGlobalAndUnknownValuesToUS() {
        XCTAssertEqual(SonioxTTSRegion.migrated(from: nil), .unitedStates)
        XCTAssertEqual(SonioxTTSRegion.migrated(from: "global"), .unitedStates)
        XCTAssertEqual(SonioxTTSRegion.migrated(from: "EUROPE"), .europe)
        XCTAssertEqual(SonioxTTSRegion.migrated(from: "jp"), .japan)
        XCTAssertEqual(SonioxTTSRegion.migrated(from: "unsupported"), .unitedStates)
    }

    func testAccountClone_ResolvesOnlyWhenReadyForV2() {
        let ready = accountVoice(id: "clone-id", name: "My Voice", status: "ready")
        let resolution = SonioxTTSCatalog.resolvedVoice(
            voiceID: "soniox/clone-id",
            accountVoices: [ready],
            lastKnownName: "Old Name"
        )

        XCTAssertEqual(resolution.apiVoiceID, "clone-id")
        XCTAssertEqual(resolution.providerVoiceID, "soniox/clone-id")
        XCTAssertEqual(resolution.displayName, "My Voice")
        XCTAssertNil(resolution.fallbackReason)
    }

    func testDeletedOrUnpreparedClone_FallsBackWithinSoniox() {
        let unprepared = accountVoice(id: "clone-id", name: "My Voice", status: "not_computed")
        let notReady = SonioxTTSCatalog.resolvedVoice(
            voiceID: "soniox/clone-id",
            accountVoices: [unprepared],
            lastKnownName: "Old Name"
        )
        let deleted = SonioxTTSCatalog.resolvedVoice(
            voiceID: "soniox/deleted-id",
            accountVoices: [],
            lastKnownName: "Remembered Voice"
        )

        XCTAssertEqual(notReady.providerVoiceID, "soniox/Maya")
        XCTAssertEqual(notReady.fallbackReason, .cloneNotReady(lastKnownName: "My Voice"))
        XCTAssertEqual(deleted.providerVoiceID, "soniox/Maya")
        XCTAssertEqual(
            deleted.fallbackReason,
            .missingOrDeletedClone(lastKnownName: "Remembered Voice")
        )
    }

    func testBlankVoiceSelection_FallsBackWithoutADeletedCloneReason() {
        for voiceID in [nil, "", "   "] as [String?] {
            let resolution = SonioxTTSCatalog.resolvedVoice(
                voiceID: voiceID,
                accountVoices: []
            )

            XCTAssertEqual(resolution.providerVoiceID, "soniox/Maya")
            XCTAssertNil(resolution.fallbackReason)
        }
    }

    private func accountVoice(id: String, name: String, status: String) -> SonioxTTSAccountVoice {
        SonioxTTSAccountVoice(
            id: id,
            name: name,
            filename: "voice.wav",
            models: [
                SonioxTTSAccountVoiceModel(
                    model: SonioxTTSCatalog.defaultModel.rawValue,
                    status: status,
                    errorType: nil,
                    errorMessage: nil
                )
            ]
        )
    }
}
