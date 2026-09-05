import XCTest
@testable import SpeakCore

final class OpenRouterAudioFilterTests: XCTestCase {
    func testSearchMatchesNamesAndDescriptionsWithinChosenCapability() throws {
        let transcription = try model(id: "provider/transcriber", modality: "transcription")
        let speech = try model(id: "provider/voice", modality: "speech")
        var filter = OpenRouterAudioFilter(query: " multilingual ")
        XCTAssertTrue(filter.matches(transcription))
        XCTAssertFalse(filter.matches(speech))
        filter.query = "EXAMPLE"
        XCTAssertTrue(filter.matches(transcription))
        filter.query = "absent term"
        XCTAssertFalse(filter.matches(transcription))
    }

    func testProviderFilterRequiresExactProviderRatherThanPrefix() throws {
        let filter = OpenRouterAudioFilter(provider: "vendor")
        XCTAssertTrue(filter.matches(try model(id: "vendor/model")))
        XCTAssertFalse(filter.matches(try model(id: "vendor-other/model")))
    }

    func testZeroPriceFilterDoesNotMislabelMissingUnknownOrNonZeroPrices() throws {
        let filter = OpenRouterAudioFilter(freeOnly: true)
        XCTAssertTrue(filter.matches(try model(pricing: ["audio_second": "0", "prompt": "0.000"])))
        XCTAssertFalse(filter.matches(try model(pricing: [:])))
        XCTAssertFalse(filter.matches(try model(pricing: ["audio_second": "unknown"])))
        XCTAssertFalse(filter.matches(try model(pricing: ["audio_second": "0.000001", "prompt": "0"])))
        XCTAssertFalse(filter.matches(try model(pricing: ["audio_second": "-1"])))
        XCTAssertFalse(filter.matches(try model(pricing: ["audio_second": "0 USD"])))
        XCTAssertFalse(filter.matches(try model(pricing: ["audio_second": "0.00invalid"])))
    }

    private func model(
        id: String = "vendor/model",
        modality: String = "transcription",
        pricing: [String: String] = [:]
    ) throws -> OpenRouterAudioModel {
        let payload: [String: Any] = [
            "id": id, "name": "Example model", "description": "Multilingual audio",
            "architecture": ["input_modalities": ["audio"], "output_modalities": [modality]],
            "pricing": pricing
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(OpenRouterAudioModel.self, from: data)
    }
}
