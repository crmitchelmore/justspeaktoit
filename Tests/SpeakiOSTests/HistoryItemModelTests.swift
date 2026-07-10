#if os(iOS)
import Foundation
import XCTest

@testable import SpeakiOSLib

/// Covers the enriched history model: raw/polished text, error state, sync
/// round-trip, and — critically — backward-compatible decoding of history JSON
/// written before these fields existed.
final class HistoryItemModelTests: XCTestCase {

    func testBestTextPrefersPolishedButPreservesRaw() {
        let raw = iOSHistoryItem(transcription: "raw", model: "m", duration: 1, wordCount: 1)
        XCTAssertEqual(raw.bestText, "raw")
        XCTAssertFalse(raw.hasPolishedText)

        let polished = raw.withPostProcessed("polished")
        XCTAssertEqual(polished.bestText, "polished")
        XCTAssertTrue(polished.hasPolishedText)
        XCTAssertEqual(polished.transcription, "raw", "raw transcript must be preserved")
    }

    func testReprocessingClearsPriorError() {
        let errored = iOSHistoryItem(transcription: "t", model: "m", duration: 1, wordCount: 1)
            .withError("boom")
        XCTAssertEqual(errored.errorMessage, "boom")
        XCTAssertNil(errored.withPostProcessed("done").errorMessage)
    }

    func testPostProcessingAdvancesUpdatedAt() {
        let createdAt = Date(timeIntervalSince1970: 10)
        let updatedAt = Date(timeIntervalSince1970: 20)
        let item = iOSHistoryItem(
            createdAt: createdAt,
            transcription: "raw",
            model: "m",
            duration: 1,
            wordCount: 1
        )

        let processed = item.withPostProcessed("done", updatedAt: updatedAt)

        XCTAssertEqual(processed.createdAt, createdAt)
        XCTAssertEqual(processed.updatedAt, updatedAt)
    }

    func testSyncRoundTripPreservesRawAndPolished() {
        let item = iOSHistoryItem(
            transcription: "raw",
            postProcessedTranscription: "polished",
            model: "m",
            duration: 2,
            wordCount: 1
        )
        let restored = iOSHistoryItem.fromSyncable(item.toSyncable())
        XCTAssertEqual(restored.transcription, "raw")
        XCTAssertEqual(restored.postProcessedTranscription, "polished")
    }

    func testDecodesLegacyJSONWithoutNewFields() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "createdAt": "2026-01-01T00:00:00Z",
          "transcription": "hello",
          "model": "apple/local/SFSpeechRecognizer",
          "duration": 1,
          "wordCount": 1,
          "originPlatform": "ios"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(iOSHistoryItem.self, from: Data(json.utf8))

        XCTAssertEqual(item.transcription, "hello")
        XCTAssertNil(item.postProcessedTranscription)
        XCTAssertNil(item.errorMessage)
        XCTAssertEqual(item.bestText, "hello")
        XCTAssertEqual(item.updatedAt, item.createdAt)
    }
}
#endif
