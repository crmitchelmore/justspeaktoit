import XCTest

@testable import SpeakCore

final class TranscriptionDisplayNameTests: XCTestCase {
    func testTranscriptionDisplayName_preservesProviderAndBatchLabels() {
        XCTAssertEqual(
            ModelCatalog.transcriptionDisplayName(
                for: "deepgram/nova-3-streaming",
                isBatch: false
            ),
            "Deepgram"
        )
        XCTAssertEqual(
            ModelCatalog.transcriptionDisplayName(
                for: XAIVoiceModels.thinkFast2CatalogID,
                isBatch: false
            ),
            "Grok Voice Think Fast 2.0 (Streaming)"
        )
        XCTAssertEqual(
            ModelCatalog.transcriptionDisplayName(
                for: "google/gemini-2.0-flash-001",
                isBatch: true
            ),
            "Gemini 2.0 Flash (OpenRouter)"
        )
    }
}
