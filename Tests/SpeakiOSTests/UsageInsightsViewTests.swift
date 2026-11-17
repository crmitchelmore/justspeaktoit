#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class UsageInsightsViewTests: XCTestCase {
    func testRecords_analyseRawTranscriptsAndSkipEntriesWithoutText() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let spoken = iOSHistoryItem(
            id: UUID(), createdAt: created, transcription: "um ship it",
            postProcessedTranscription: "Ship it.", model: "openai/gpt-transcribe", duration: 12, wordCount: 3
        )
        let silent = iOSHistoryItem(
            id: UUID(), createdAt: created, transcription: " ", postProcessedTranscription: nil,
            model: "openai/gpt-transcribe", duration: 3, wordCount: 0
        )

        let records = UsageInsightsView.records(from: [spoken, silent])

        XCTAssertEqual(records.map(\.id), [spoken.id])
        XCTAssertEqual(records.first?.text, "um ship it")
        XCTAssertEqual(records.first?.duration, 12)
        let summary = SpeechInsightsEngine.summary(for: SpeechInsightsEngine.computeAggregate(from: records))
        XCTAssertEqual(summary.topFillers.map(\.term), ["um"])
    }

    func testDuration_matchesTheHistoryHeaderFormat() {
        XCTAssertEqual(UsageInsightsView.duration(0), "0s")
        XCTAssertEqual(UsageInsightsView.duration(59.9), "59s")
        XCTAssertEqual(UsageInsightsView.duration(125), "2m 5s")
    }
}
#endif
