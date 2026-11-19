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
                for: XAIVoiceModels.voice3CatalogID,
                isBatch: false
            ),
            "Grok Voice 3.0 (Streaming)"
        )
        XCTAssertEqual(
            ModelCatalog.transcriptionDisplayName(
                for: "google/gemini-3.1-flash-lite",
                isBatch: true
            ),
            "Gemini 3.1 Flash Lite (OpenRouter)"
        )
    }
}
