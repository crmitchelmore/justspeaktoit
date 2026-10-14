import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

final class DesktopHistoryFilterTests: XCTestCase {
    func testErrorFilterIncludesTranscriptionAndPostProcessingFailures() {
        let success = record()
        var transcription = record()
        transcription.failure = "Synthetic transcription failure"
        var processing = record()
        processing.postProcessingFailure = "Synthetic processing failure"
        let pending = record()
        let filtered = DesktopHistorySearch.filter(
            [success, transcription, processing, pending], query: "",
            constraints: HistorySearchQuery(includeErrorsOnly: true)
        )
        XCTAssertEqual(Set(filtered.map(\.id)), [transcription.id, processing.id])
        XCTAssertNil(success.failure)
        XCTAssertNil(pending.result)
    }

    func testModelFilterMatchesRecordedAndProcessingModelsWithoutChangingRecords() {
        var first = record(model: "openai/whisper-1")
        first.postProcessingModelIdentifier = "openai/gpt-5-mini"
        let second = record(model: "deepgram/nova-3")
        let models = DesktopHistorySearch.availableModels(in: [first, second, first])
        XCTAssertEqual(Set(models), ["openai/whisper-1", "deepgram/nova-3", "openai/gpt-5-mini"])
        let filtered = DesktopHistorySearch.filter(
            [second, first], query: "",
            constraints: HistorySearchQuery(modelIdentifiers: ["OPENAI/GPT-5-MINI"])
        )
        XCTAssertEqual(filtered.map(\.id), [first.id])
        XCTAssertEqual(filtered.first?.postProcessingModelIdentifier, first.postProcessingModelIdentifier)
        XCTAssertTrue(DesktopHistorySearch.filter(
            [first, second], query: "", constraints: HistorySearchQuery(modelIdentifiers: ["unknown/model"])
        ).isEmpty)
    }

    func testDateRangeUsesCanonicalLocalDaysAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let range = HistorySearchQuery.normalizedDayRange(from: start, through: start, calendar: calendar)
        let before = record(createdAt: range.lowerBound.addingTimeInterval(-1))
        let beginning = record(createdAt: range.lowerBound)
        let end = record(createdAt: range.upperBound)
        let after = record(createdAt: range.upperBound.addingTimeInterval(1))
        let filtered = DesktopHistorySearch.filter(
            [after, beginning, before, end], query: "", constraints: HistorySearchQuery(dateRange: range)
        )
        XCTAssertEqual(filtered.map(\.id), [end.id, beginning.id])
        XCTAssertEqual(range.upperBound.timeIntervalSince(range.lowerBound), 23 * 3600 - 1)
    }

    func testSearchAndAllCriteriaComposeAndResetKeepsStableOrder() {
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        var match = record(model: "openai/whisper-1", createdAt: time)
        match.profileName = "Café notes"
        match.failure = "Synthetic failure"
        var outside = record(model: "openai/whisper-1", createdAt: time.addingTimeInterval(-100))
        outside.profileName = match.profileName
        outside.failure = match.failure
        let criteria = HistorySearchQuery(
            modelIdentifiers: ["openai/whisper-1"], includeErrorsOnly: true,
            dateRange: time.addingTimeInterval(-10)...time.addingTimeInterval(10)
        )
        XCTAssertEqual(DesktopHistorySearch.filter(
            [outside, match], query: "CAFE", constraints: criteria
        ).map(\.id), [match.id])
        XCTAssertEqual(DesktopHistorySearch.filter([outside, match], query: "").map(\.id), [match.id, outside.id])
        XCTAssertEqual(match.profileName, "Café notes")
    }

    func testNativeDraftRejectsInvalidDatesAndReversedRanges() throws {
        for day in ["2026-02-29", "2026-13-01", "2026-01-00", "2026-03-32", "26-01-01", "2026-1-01",
                    "2026-01-01 ", "0000-01-01", "2026-+1-01"] {
            XCTAssertThrowsError(try DesktopHistoryFilter(fromDay: day).query(), day)
            XCTAssertThrowsError(try DesktopHistoryFilter(throughDay: day).query(), day)
        }
        XCTAssertThrowsError(try DesktopHistoryFilter(fromDay: "2026-10-10", throughDay: "2026-10-09").query())
        XCTAssertNoThrow(try DesktopHistoryFilter(fromDay: "2024-02-29").query())
        XCTAssertEqual(try DesktopHistoryFilter.none.query(), .none)
    }

    func testNativeDraftSupportsIndependentBoundariesAndMultipleModels() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let start = try DesktopHistoryFilter(fromDay: "2026-10-10").query(timeZone: zone)
        let end = try DesktopHistoryFilter(throughDay: "2026-10-10").query(timeZone: zone)
        let both = try DesktopHistoryFilter(
            models: ["openai/whisper-1", "deepgram/nova-3"], errorsOnly: true,
            fromDay: "2026-10-10", throughDay: "2026-10-10"
        ).query(timeZone: zone)
        let startRange = try XCTUnwrap(start.dateRange), endRange = try XCTUnwrap(end.dateRange)
        XCTAssertEqual(startRange.upperBound.timeIntervalSince1970, .infinity)
        XCTAssertEqual(endRange.lowerBound.timeIntervalSince1970, -.infinity)
        XCTAssertNoThrow(try DesktopHistoryFilter(fromDay: "9999-12-31").query(timeZone: zone))
        XCTAssertEqual(both.dateRange, startRange.lowerBound...endRange.upperBound)
        XCTAssertEqual(both.modelIdentifiers, ["openai/whisper-1", "deepgram/nova-3"])
        XCTAssertTrue(both.includeErrorsOnly)
    }

    func testResultModelAndProcessingFriendlyNameAreSearchable() {
        var entry = record(model: "openai/whisper-1")
        entry.result = TranscriptionResult(
            text: "Synthetic transcript", segments: [], confidence: nil, duration: 1,
            modelIdentifier: "deepgram/nova-3", cost: nil, rawPayload: nil, debugInfo: nil
        )
        entry.postProcessingModelIdentifier = "openrouter/example/model"
        XCTAssertEqual(DesktopHistorySearch.filter(
            [entry], query: "", constraints: HistorySearchQuery(modelIdentifiers: ["deepgram/nova-3"])
        ).map(\.id), [entry.id])
        XCTAssertEqual(DesktopHistorySearch.filter(
            [entry], query: DesktopHistorySearch.modelDisplayName(for: entry.postProcessingModelIdentifier!)
        ).map(\.id), [entry.id])
    }

    private func record(
        model: String = "openai/whisper-1", createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> DesktopRecordingStore.Record {
        DesktopRecordingStore.Record(id: UUID(), audioFilename: "synthetic.wav", modelIdentifier: model,
                                     createdAt: createdAt)
    }
}
