import Foundation
import XCTest

@testable import SpeakCore

final class OpenRouterSpeechSelectionTests: XCTestCase {
    func testSelection_RoundTripsProviderSlashesAndVoicePunctuation() throws {
        let selection = OpenRouterSpeechSelection(modelID: "provider/model:variant", voice: "voice/name:one")
        XCTAssertEqual(OpenRouterSpeechSelection(id: selection.id), selection)
        XCTAssertEqual(selection.id, OpenRouterSpeechSelection(modelID: selection.modelID, voice: selection.voice).id)
        XCTAssertTrue(selection.id.hasPrefix("openrouter/speech/"))
        let decoded = try JSONDecoder().decode(
            OpenRouterSpeechSelection.self, from: JSONEncoder().encode(selection)
        )
        XCTAssertEqual(decoded, selection)
    }

    func testDefaultVoice_IsDistinctFromExplicitVoice() {
        let defaultVoice = OpenRouterSpeechSelection(modelID: "provider/model")
        let explicitVoice = OpenRouterSpeechSelection(modelID: "provider/model", voice: "alloy")
        XCTAssertNotEqual(defaultVoice.id, explicitVoice.id)
        XCTAssertEqual(OpenRouterSpeechSelection(id: defaultVoice.id), defaultVoice)
    }

    func testMalformedSelections_AreRejected() {
        let invalid = [
            "", "openai/alloy", "openrouter/speech/", "openrouter/speech/%%%",
            OpenRouterSpeechSelection(modelID: "").id,
            OpenRouterSpeechSelection(modelID: "provider/with space").id,
            OpenRouterSpeechSelection(modelID: "provider/model", voice: " ").id,
            OpenRouterSpeechSelection(modelID: "provider/model", voice: "voice\n").id,
            OpenRouterSpeechSelection(modelID: "provider/model").id + "="
        ]
        for identifier in invalid {
            XCTAssertNil(OpenRouterSpeechSelection(id: identifier), identifier)
        }
    }
}
