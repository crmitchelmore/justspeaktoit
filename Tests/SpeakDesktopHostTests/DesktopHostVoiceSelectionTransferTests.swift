import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

final class DesktopHostVoiceSelectionTransferTests: XCTestCase {
    func testScalarImport_UsesSoleAuthorityAndCatalogueDefaultWithoutChangingUnrelatedControls() throws {
        var saved = DesktopVoiceOutputSettings()
        saved.format = "future-format"; saved.speed = 1.25; saved.sonioxRegion = "eu"; saved.language = "fr"
        saved.autoPlay = false; saved.saveToRecordings = true
        try saved.applyConfigurationProjection(["defaultTTSVoice": AnyCodable(.string("openai/alloy"))])
        XCTAssertEqual(saved.modelID, OpenAITTSCatalog.defaultModel.desktopModelIdentifier)
        XCTAssertEqual(saved.voiceID, "openai/alloy")
        XCTAssertEqual(saved.strictVoiceSelection, true)
        XCTAssertEqual(try saved.resolvedVoice(accountInventory: nil).modelID, saved.modelID)
        XCTAssertEqual(saved.format, "future-format")
        XCTAssertEqual(saved.speed, 1.25)
        XCTAssertEqual(saved.sonioxRegion, "eu")
        XCTAssertEqual(saved.language, "fr")
        XCTAssertEqual(saved.generationOptions, .init(autoPlay: false, saveToRecordings: true))
    }

    func testNativeAdvancedModels_ScalarAndFullRoundTripsNeverCollapseExplicitModelsOrQuality() throws {
        let voices = DesktopSpeechVoice.voices.filter {
            if case .openai = $0 { return true }
            if case .elevenlabs = $0 { return true }
            if case .gemini = $0 { return true }
            return false
        }
        for voice in voices {
            var original = DesktopVoiceOutputSettings(voice: voice)
            original.quality = voice.defaultQuality.rawValue
            original.format = "m4a"; original.speed = 1.25
            var scalar = original
            try scalar.applyConfigurationProjection(["defaultTTSVoice": AnyCodable(.string(voice.transferVoiceID))])
            XCTAssertEqual(scalar.modelID, original.modelID)
            XCTAssertEqual(scalar.voiceID, original.voiceID)
            XCTAssertEqual(scalar.quality, original.quality)
            let projection = original.configurationProjection(over: [:])
            XCTAssertEqual(projection[VoiceSelectionPreference.modelKey], AnyCodable(.string(voice.modelID)))
            var restored = DesktopVoiceOutputSettings()
            try restored.applyConfigurationProjection(projection)
            XCTAssertEqual(restored.modelID, original.modelID)
            XCTAssertEqual(restored.voiceID, original.voiceID)
            XCTAssertEqual(restored.quality, original.quality)
            XCTAssertEqual(restored.format, original.format)
            XCTAssertEqual(restored.speed, original.speed)
            XCTAssertEqual(try restored.resolvedVoice(accountInventory: nil),
                           try original.resolvedVoice(accountInventory: nil))
        }
    }

    func testUnknownAndUnsupportedIntents_RoundTripExactlyAndExposeUnavailableNativePicker() throws {
        for raw in ["future", "deepgram/future", "apple/local/en-US", "openrouter/future/model/voice",
                    "mistral/account-only", "xai/account-only", "soniox/future", " Future/Case\tVoice ", ""] {
            var saved = DesktopVoiceOutputSettings()
            try saved.applyConfigurationProjection(["defaultTTSVoice": AnyCodable(.string(raw))])
            XCTAssertEqual(saved.voiceID, raw)
            XCTAssertNil(saved.modelID)
            XCTAssertThrowsError(try saved.synthesisSelection())
            let picker = saved.favoritePicker(accountInventory: nil)
            XCTAssertEqual(picker.selected, picker.labels.count - 1)
            XCTAssertTrue(picker.labels[picker.selected].contains("Unavailable"))
            XCTAssertEqual(picker.identifiers[picker.selected], "")
            XCTAssertEqual(saved.controlsPresentation.capabilities, 0)
            let projection = saved.configurationProjection(over: [:])
            XCTAssertEqual(projection["defaultTTSVoice"], AnyCodable(.string(raw)))
            let restarted = try JSONDecoder().decode(DesktopVoiceOutputSettings.self,
                from: JSONEncoder().encode(saved))
            XCTAssertEqual(restarted, saved)
            XCTAssertThrowsError(try restarted.synthesisSelection())
        }
    }

    func testPartialModelAndUnrelatedImports_PreserveRawIntentAndRejectUnknownModelWithoutFallback() throws {
        var saved = DesktopVoiceOutputSettings(voice: .deepgram(DeepgramSpeechCatalog.voices[0]))
        let previous = saved
        try saved.applyConfigurationProjection(["ttsAutoPlay": AnyCodable(.bool(false))])
        XCTAssertEqual(saved.modelID, previous.modelID)
        XCTAssertEqual(saved.voiceID, previous.voiceID)
        XCTAssertNil(saved.strictVoiceSelection)
        try saved.applyConfigurationProjection([
            VoiceSelectionPreference.modelKey: AnyCodable(.string(" Future Model "))
        ])
        XCTAssertEqual(saved.voiceID, previous.voiceID)
        XCTAssertEqual(saved.modelID, " Future Model ")
        XCTAssertThrowsError(try saved.storedVoice(accountInventory: nil))
        XCTAssertEqual(saved.configurationProjection(over: [:])[VoiceSelectionPreference.modelKey],
                       AnyCodable(.string(" Future Model ")))
        let before = saved
        for key in VoiceSelectionPreference.keys {
            XCTAssertThrowsError(try saved.applyConfigurationProjection([
                key: AnyCodable(.bool(true)), "ttsAutoPlay": AnyCodable(.bool(true))
            ]))
            XCTAssertEqual(saved, before)
        }
    }

    func testAbsentSelection_RemainsLegacyAndDoesNotMaterializeMacDefaultOrSecondPreferenceMirror() throws {
        var saved = DesktopVoiceOutputSettings()
        try saved.applyConfigurationProjection([:])
        XCTAssertNil(saved.modelID); XCTAssertNil(saved.voiceID); XCTAssertNil(saved.strictVoiceSelection)
        let projection = saved.configurationProjection(over: [:])
        XCTAssertNil(projection[VoiceSelectionPreference.key])
        XCTAssertNil(projection[VoiceSelectionPreference.modelKey])
        XCTAssertEqual(try saved.synthesisSelection().voice,
                       .deepgram(DeepgramSpeechCatalog.resolvedSelection(modelID: nil, voiceID: nil).voice))
        let raw = try JSONDecoder().decode([String: AnyCodable].self, from: JSONEncoder().encode(saved))
        XCTAssertNil(raw[VoiceSelectionPreference.key])
        XCTAssertNil(raw[VoiceSelectionPreference.modelKey])
        XCTAssertNil(raw["strictVoiceSelection"])
    }

    func testHostWithoutVoiceBridge_PreservesExplicitVoiceAndModelButNeverAppliesThem() throws {
        let configuration = try DesktopConfiguration(values: [
            VoiceSelectionPreference.key: AnyCodable(.string("apple/local/en-US")),
            VoiceSelectionPreference.modelKey: AnyCodable(.string("future-model"))
        ])
        var voice: FakeLocalPlatform.VoiceOutputSettings?
        let result = try FakeLocalPlatform.importVoiceConfiguration(from: configuration, into: &voice)
        XCTAssertNil(voice)
        XCTAssertEqual(result, configuration)
        XCTAssertTrue(FakeLocalPlatform.voiceConfigurationKeys.isEmpty)
    }

    func testExplicitChangedModelWithoutQuality_DoesNotInheritAQualityThatWouldUndoIt() throws {
        var saved = DesktopVoiceOutputSettings(modelID: OpenAITTSModel.mini.desktopModelIdentifier,
                                               voiceID: "openai/alloy")
        saved.quality = VoiceSynthesisQuality.standard.rawValue
        try saved.applyConfigurationProjection([
            VoiceSelectionPreference.modelKey:
                AnyCodable(.string(OpenAITTSModel.highDefinition.desktopModelIdentifier))
        ])
        XCTAssertNil(saved.quality)
        XCTAssertEqual(try saved.synthesisSelection().voice.modelID,
                       OpenAITTSModel.highDefinition.desktopModelIdentifier)
        let projected = saved.configurationProjection(over: [:])
        var restored = DesktopVoiceOutputSettings()
        try restored.applyConfigurationProjection(projected)
        XCTAssertNil(restored.quality)
        XCTAssertEqual(try restored.synthesisSelection().voice.modelID,
                       OpenAITTSModel.highDefinition.desktopModelIdentifier)
    }
}
