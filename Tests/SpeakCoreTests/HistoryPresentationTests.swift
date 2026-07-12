import XCTest

@testable import SpeakCore

final class HistoryPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testQuery_matchesProcessedTextFriendlyModelAndFilters() {
        let item = makeItem(
            raw: "raw words",
            processed: "Polished sentence",
            models: ["openai/gpt-5.6-luna"],
            errors: 1
        )

        XCTAssertTrue(HistorySearchQuery(searchText: "polished").matches(item))
        XCTAssertTrue(HistorySearchQuery(searchText: "GPT-5.6 Luna").matches(item))
        XCTAssertTrue(HistorySearchQuery(includeErrorsOnly: true).matches(item))
        XCTAssertTrue(HistorySearchQuery(modelIdentifiers: ["OPENAI/GPT-5.6-LUNA"]).matches(item))
        XCTAssertFalse(HistorySearchQuery(modelIdentifiers: ["openai/gpt-5-mini"]).matches(item))
    }

    func testStatistics_usesBestTranscriptAndAggregatesSharedMetrics() {
        let items = [
            makeItem(raw: "one two", processed: "one two three", duration: 20, cost: 0.1, errors: 1),
            makeItem(raw: "four five", duration: 40, cost: 0.2)
        ]

        let statistics = HistoryPresentationStatistics(items: items)

        XCTAssertEqual(statistics.totalSessions, 2)
        XCTAssertEqual(statistics.cumulativeRecordingDuration, 60)
        XCTAssertEqual(statistics.averageSessionLength, 30)
        XCTAssertEqual(statistics.totalWords, 5)
        XCTAssertEqual(statistics.sessionsWithErrors, 1)
        XCTAssertEqual(statistics.totalSpend, Decimal(string: "0.3"))
    }

    private func makeItem(
        raw: String,
        processed: String? = nil,
        models: [String] = ["apple/local/SFSpeechRecognizer"],
        duration: TimeInterval = 10,
        cost: Decimal = 0,
        errors: Int = 0
    ) -> HistoryPresentationItem {
        HistoryPresentationItem(
            id: UUID(),
            createdAt: now,
            rawTranscription: raw,
            processedTranscription: processed,
            modelIdentifiers: models,
            recordingDuration: duration,
            cost: cost,
            errorCount: errors,
            originPlatform: "test"
        )
    }
}
