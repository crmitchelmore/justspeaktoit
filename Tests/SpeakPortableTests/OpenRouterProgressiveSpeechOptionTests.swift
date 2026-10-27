import Foundation
import XCTest

@testable import SpeakCore

final class OpenRouterProgressiveSpeechOptionTests: XCTestCase {
    func testDisabledNeverAdmitsAnOtherwiseValidSelection() {
        let selection = OpenRouterSpeechSelection(modelID: "vendor/speech", voice: "voice")
        XCTAssertFalse(OpenRouterProgressiveSpeechOption.disabled.allows(selection))
    }

    func testOnlyTheExactCommissionedModelAndVoiceAreAdmitted() throws {
        let selection = OpenRouterSpeechSelection(modelID: "vendor/speech", voice: "voice")
        let option = try XCTUnwrap(OpenRouterProgressiveSpeechOption(selectionID: selection.id))
        XCTAssertTrue(option.allows(selection))
        XCTAssertFalse(option.allows(OpenRouterSpeechSelection(modelID: "vendor/other", voice: "voice")))
        XCTAssertFalse(option.allows(OpenRouterSpeechSelection(modelID: "vendor/speech", voice: "other")))
        XCTAssertFalse(option.allows(OpenRouterSpeechSelection(modelID: "vendor/speech")))
        XCTAssertNotEqual(option, .disabled)
    }

    func testModelDefaultVoiceDoesNotAdmitExplicitVoices() throws {
        let selection = OpenRouterSpeechSelection(modelID: "vendor/speech")
        let option = try XCTUnwrap(OpenRouterProgressiveSpeechOption(selectionID: selection.id))
        XCTAssertTrue(option.allows(selection))
        XCTAssertFalse(option.allows(OpenRouterSpeechSelection(modelID: selection.modelID, voice: "voice")))
    }

    func testInvalidAndNoncanonicalSelectionIDsCannotCommission() {
        let valid = OpenRouterSpeechSelection(modelID: "vendor/speech", voice: "voice").id
        let invalidModel = OpenRouterSpeechSelection(modelID: "", voice: "voice").id
        let invalidVoice = OpenRouterSpeechSelection(modelID: "vendor/speech", voice: " ").id
        for id in ["", "vendor/speech", valid + "=", invalidModel, invalidVoice] {
            XCTAssertNil(OpenRouterProgressiveSpeechOption(selectionID: id), id)
        }
    }

    func testCanonicalASCIIIdentityDoesNotMergeEquivalentUnicodeVoiceSpellings() throws {
        let composed = OpenRouterSpeechSelection(modelID: "vendor/speech", voice: "caf\u{00E9}")
        let decomposed = OpenRouterSpeechSelection(modelID: "vendor/speech", voice: "cafe\u{0301}")
        XCTAssertEqual(composed.voice, decomposed.voice, "Swift strings consider these spellings equivalent")
        XCTAssertNotEqual(composed.id, decomposed.id, "Provider request spellings remain distinct")
        let option = try XCTUnwrap(OpenRouterProgressiveSpeechOption(selectionID: composed.id))
        XCTAssertTrue(option.allows(composed))
        XCTAssertFalse(option.allows(decomposed))
        XCTAssertNotEqual(option, OpenRouterProgressiveSpeechOption(selectionID: decomposed.id))
    }
}
