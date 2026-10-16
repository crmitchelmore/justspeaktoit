import Foundation
import SpeakCore
@testable import SpeakDesktopHost
import XCTest

final class DesktopHostVoiceMarkupTests: XCTestCase {
    func testHelperAvailability_RequiresBothAnExecutableSSMLRouteAndItsExplicitToggle() {
        for voice in DesktopSpeechVoice.voices {
            var saved = DesktopVoiceOutputSettings(voice: voice)
            XCTAssertFalse(saved.controlsPresentation.markupHelperEnabled)
            saved.useSSML = true
            XCTAssertEqual(saved.controlsPresentation.markupHelperEnabled, voice.capabilities.ssml)
            XCTAssertEqual(saved.voiceID, voice.id)
            XCTAssertEqual(saved.modelID, voice.modelID)
        }
    }

    func testUnsupportedStoredVoiceOrQuality_NeverEnablesAnEditingHelperAsAnExecutableRoute() {
        var unknown = DesktopVoiceOutputSettings(modelID: "future/model", voiceID: "future/voice")
        unknown.useSSML = true
        XCTAssertFalse(unknown.controlsPresentation.markupHelperEnabled)
        var quality = DesktopVoiceOutputSettings(voice: .azureNeural(AzureNeuralVoiceCatalog.voices[0]))
        quality.useSSML = true
        quality.quality = "future-quality"
        XCTAssertFalse(quality.controlsPresentation.markupHelperEnabled)
        XCTAssertEqual(quality.quality, "future-quality")
    }

    func testLocalWrapping_DoesNotMutateSavedControlsOrAnAlreadyCapturedSynthesisSelection() throws {
        var saved = DesktopVoiceOutputSettings(voice: .azureNeural(AzureNeuralVoiceCatalog.voices[0]))
        saved.useSSML = true
        saved.speed = 1
        saved.pitch = 0
        saved.quality = "highest"
        saved.language = "en_GB"
        saved.favoriteVoices = ["future/voice"]
        let before = saved
        let selection = try saved.synthesisSelection()
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic original.")
        let wrapped = VoiceSynthesisMarkup.wrapping(source.text)
        XCTAssertEqual(wrapped, "<speak>Synthetic original.</speak>")
        XCTAssertEqual(source.text, "Synthetic original.")
        XCTAssertEqual(saved, before)
        XCTAssertEqual(try saved.synthesisSelection(), selection)
        let legacy = try JSONDecoder().decode(VoiceSynthesisOptions.self,
            from: Data(#"{"speed":1,"pitch":0,"useSSML":true}"#.utf8))
        XCTAssertNil(legacy.quality)
        XCTAssertTrue(legacy.useSSML)
    }
}
