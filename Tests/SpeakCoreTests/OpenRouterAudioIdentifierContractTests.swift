import Foundation
import XCTest

@testable import SpeakCore

final class OpenRouterAudioIdentifierContractTests: XCTestCase {
    func testMetadataAndSavedSelections_UseSameModelIdentifierLimit() throws {
        let atLimit = "vendor/" + String(repeating: "m", count: 505)
        let overLimit = atLimit + "m"
        let response = try decode(models: [atLimit, overLimit, "vendor/valid"])
        XCTAssertEqual(response.data.map(\.id), [atLimit, "vendor/valid"])
        XCTAssertEqual(OpenRouterAudioClient.transcriptionPrefix, OpenRouterTranscriptionSelection.prefix)
        for model in response.data {
            XCTAssertEqual(OpenRouterTranscriptionSelection.modelID(from: model.transcriptionSelectionID), model.id)
            let speech = OpenRouterSpeechSelection(modelID: model.id)
            XCTAssertEqual(OpenRouterSpeechSelection(id: speech.id), speech)
        }
        XCTAssertNil(OpenRouterTranscriptionSelection.modelID(
            from: OpenRouterTranscriptionSelection.identifier(for: overLimit)
        ))
        XCTAssertNil(OpenRouterSpeechSelection(id: OpenRouterSpeechSelection(modelID: overLimit).id))
    }

    func testMalformedVoiceMetadata_DoesNotCreateUnusableOrDuplicateChoices() throws {
        let voices = [
            "valid/voice:one", "", " ", "invalid\nvoice", String(repeating: "v", count: 513), "valid/voice:one"
        ]
        let envelope: [String: Any] = ["data": [[
            "id": "vendor/tts", "architecture": ["input_modalities": ["text"], "output_modalities": ["speech"]],
            "supported_voices": voices
        ]]]
        let response = try JSONDecoder().decode(
            OpenRouterAudioModelResponse.self, from: JSONSerialization.data(withJSONObject: envelope)
        )
        let model = try XCTUnwrap(response.data.first)
        XCTAssertEqual(model.supportedVoices, ["valid/voice:one"])
        for voice in model.supportedVoices {
            let selection = OpenRouterSpeechSelection(modelID: model.id, voice: voice)
            XCTAssertEqual(OpenRouterSpeechSelection(id: selection.id), selection)
        }
    }

    private func decode(models: [String]) throws -> OpenRouterAudioModelResponse {
        let entries = models.map { identifier -> [String: Any] in
            ["id": identifier, "architecture": ["input_modalities": ["audio"], "output_modalities": ["transcription"]]]
        }
        return try JSONDecoder().decode(
            OpenRouterAudioModelResponse.self, from: JSONSerialization.data(withJSONObject: ["data": entries])
        )
    }
}
