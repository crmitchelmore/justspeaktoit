import Foundation
import SpeakCore
import XCTest

final class DesktopVoiceSelectionPreferenceTests: XCTestCase {
    func testEveryCanonicalStaticPair_StrictTransferUsesExistingModelAndVoiceWithoutFallback() throws {
        for voice in DesktopSpeechVoice.voices {
            let explicit = try DesktopSpeechVoice.strictlyResolved(
                modelID: voice.modelID, voiceID: voice.transferVoiceID)
            XCTAssertEqual(explicit, voice)
            if case .openai(_, let preset) = voice, !preset.supports(OpenAITTSCatalog.defaultModel) {
                XCTAssertThrowsError(try DesktopSpeechVoice.strictlyResolved(
                    modelID: nil, voiceID: voice.transferVoiceID))
            } else {
                let scalar = try DesktopSpeechVoice.strictlyResolved(modelID: nil, voiceID: voice.transferVoiceID)
                XCTAssertEqual(scalar.transferVoiceID, voice.transferVoiceID)
                XCTAssertTrue(DesktopSpeechVoice.voices.contains(scalar))
            }
        }
        let alloy = try DesktopSpeechVoice.strictlyResolved(modelID: nil, voiceID: "openai/alloy")
        XCTAssertEqual(alloy.modelID, OpenAITTSCatalog.defaultModel.desktopModelIdentifier)
        let rachel = try DesktopSpeechVoice.strictlyResolved(modelID: nil, voiceID: "elevenlabs/rachel")
        XCTAssertEqual(rachel.modelID, ElevenLabsTTSCatalog.defaultModel.desktopModelIdentifier)
    }

    func testLegacyAliases_UseOnlyExistingCanonicalMigrationsAndPreserveCaseSensitiveIDs() throws {
        for (legacy, canonical) in ElevenLabsTTSCatalog.legacyVoiceIdentifiers {
            let migrated = try DesktopSpeechVoice.strictlyResolved(modelID: nil, voiceID: legacy)
            XCTAssertEqual(migrated.transferVoiceID, canonical)
        }
        for model in ["aura_1", "aura-1", "aura_2", "aura2"] {
            let exact = try DesktopSpeechVoice.strictlyResolved(modelID: model, voiceID: "deepgram/Asteria")
            let incumbent = DeepgramSpeechCatalog.resolvedSelection(modelID: model, voiceID: "deepgram/Asteria")
            XCTAssertEqual(exact, .deepgram(incumbent.voice))
        }
        let canonical = try XCTUnwrap(ElevenLabsTTSCatalog.voices.first)
        XCTAssertEqual(try DesktopSpeechVoice.strictlyResolved(modelID: nil, voiceID: canonical.providerVoiceID).id,
                       canonical.providerVoiceID)
        XCTAssertThrowsError(try DesktopSpeechVoice.strictlyResolved(
            modelID: nil, voiceID: canonical.providerVoiceID.lowercased()))
    }

    func testUnsupportedRawIntent_RefusesWhileOriginalNativeDefaultAndResolverAritiesRemain() throws {
        for raw in ["future", "deepgram/future", "alloy", "apple/local/en-US", "system/Alex",
                    "openrouter/future/model/voice", "mistral/account-only", "xai/account-only", "soniox/future", ""] {
            XCTAssertThrowsError(try DesktopSpeechVoice.strictlyResolved(modelID: nil, voiceID: raw), raw)
        }
        let deepgram = try XCTUnwrap(DeepgramSpeechCatalog.voices.first)
        XCTAssertThrowsError(try DesktopSpeechVoice.strictlyResolved(
            modelID: "future-model", voiceID: deepgram.providerVoiceID))
        XCTAssertThrowsError(try DesktopSpeechVoice.strictlyResolved(modelID: "future-model", voiceID: "openai/alloy"))
        let legacy = try DesktopSpeechVoice.resolved(modelID: nil, voiceID: "future")
        XCTAssertEqual(legacy, .deepgram(
            DeepgramSpeechCatalog.resolvedSelection(modelID: nil, voiceID: "future").voice))
        XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: nil, voiceID: nil),
                       try DesktopSpeechVoice.resolved(modelID: nil, voiceID: nil, xaiInventory: nil))
    }

    func testTransferMetadata_MissingKeysStayAbsentAndMalformedScalarsAreNotAccepted() throws {
        XCTAssertTrue(DesktopConfiguration.voiceTransferKeys.isSuperset(of: VoiceSelectionPreference.keys))
        XCTAssertEqual(VoiceSelectionPreference.key, ApplicationPreferenceKey.defaultTTSVoice.rawValue)
        let empty = try VoiceSelectionPreference.Update(preferences: [:])
        XCTAssertNil(empty.voiceID)
        XCTAssertNil(empty.modelID)
        let raw = " Future/Case-Sensitive\tVoice "
        let imported = try VoiceSelectionPreference.Update(preferences: [
            VoiceSelectionPreference.key: AnyCodable(.string(raw))
        ])
        XCTAssertEqual(imported.voiceID, raw)
        for key in VoiceSelectionPreference.keys {
            XCTAssertThrowsError(try VoiceSelectionPreference.Update(preferences: [key: AnyCodable(.int(7))]))
        }
    }

    func testFluxShortNames_AreNotInventedAliasesEvenWhenTheDefaultVoiceHasTheSameName() throws {
        for voice in DeepgramSpeechCatalog.fluxVoices {
            XCTAssertThrowsError(try DesktopSpeechVoice.strictlyResolved(
                modelID: DeepgramSpeechCatalog.flux.id, voiceID: voice.name))
            XCTAssertEqual(try DesktopSpeechVoice.strictlyResolved(
                modelID: DeepgramSpeechCatalog.flux.id, voiceID: voice.providerVoiceID), .deepgram(voice))
        }
    }
}
