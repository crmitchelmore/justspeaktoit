import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopHistoryPresentationTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    private func record(
        text: String? = "Could we move the catch-up to Friday?", duration: TimeInterval = 24,
        cost: Decimal? = nil, failure: String? = nil
    ) -> DesktopRecordingStore.Record {
        var record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "a.wav", modelIdentifier: "openai/whisper-1"
        )
        if let text {
            record.result = TranscriptionResult(
                text: text, segments: [], confidence: nil, duration: duration, modelIdentifier: "openai/whisper-1",
                cost: cost.map { ChatCostBreakdown(inputTokens: 0, outputTokens: 0, totalCost: $0, currency: "USD") },
                rawPayload: nil, debugInfo: nil
            )
        }
        record.failure = failure
        return record
    }

    func testInsights_countSessionsErrorsTimeAndSpendLikeTheMac() {
        var polishFailed = record(duration: 30, cost: Decimal(string: "0.05")!)
        polishFailed.postProcessingFailure = "timed out"
        let insights = DesktopHistoryInsights(records: [
            record(duration: 24, cost: Decimal(string: "0.08")!),
            polishFailed,
            record(text: nil, failure: "The network is offline."),
        ])
        XCTAssertEqual(insights.sessions, 3)
        XCTAssertEqual(insights.sessionsWithErrors, 2)
        XCTAssertEqual(insights.recordingDuration, 54)
        XCTAssertEqual(insights.averageSessionLength, 18)
        XCTAssertEqual(insights.spend, Decimal(string: "0.13")!)
        XCTAssertEqual(DesktopHistoryInsights(records: []), .empty)
        XCTAssertEqual(DesktopHistoryInsights.empty.averageSessionLength, 0)
    }

    func testFormat_matchesTheMacDashboardHeaderAndRows() {
        XCTAssertEqual(DesktopHistoryFormat.totalDuration(0), "—")
        XCTAssertEqual(DesktopHistoryFormat.totalDuration(956), "15m 56s")
        XCTAssertEqual(DesktopHistoryFormat.totalDuration(68.9), "01m 08s")
        XCTAssertEqual(DesktopHistoryFormat.spend(0, locale: locale), "—")
        XCTAssertEqual(DesktopHistoryFormat.spend(Decimal(string: "0.13")!, locale: locale), "$0.13")
        XCTAssertEqual(DesktopHistoryFormat.spend(Decimal(string: "0.0021")!, locale: locale), "<$0.01")
        XCTAssertEqual(DesktopHistoryFormat.spend(Decimal(string: "0.01")!, locale: locale), "$0.01")
        XCTAssertEqual(DesktopHistoryFormat.audioLength(24), "24.00")
        XCTAssertEqual(DesktopHistoryFormat.audioLength(7.236), "07.24")
        XCTAssertEqual(DesktopHistoryFormat.audioLength(67.24), "01:07.24")
        XCTAssertEqual(DesktopHistoryFormat.audioLength(-1), "—")
        // ICU separates the time from "PM" with a narrow no-break space.
        let created = DesktopHistoryFormat.created(
            Date(timeIntervalSince1970: 1_788_892_860), locale: locale, timeZone: utc
        )
        XCTAssertEqual(created.replacingOccurrences(of: "\u{202F}", with: " "), "Sep 8, 2026 at 6:41 PM")
    }

    func testRowSummary_describesTranscriptModelsCostAndOrigin() {
        var polished = record(cost: Decimal(string: "0.02")!)
        polished.processedText = "Could we move the catch-up to Friday?\nThanks."
        polished.postProcessingModelIdentifier = "openrouter/openai/gpt-5-mini"
        polished.profileName = "Email"
        let names = ["openai/whisper-1": "OpenAI Whisper", "openrouter/openai/gpt-5-mini": "GPT-5 mini"]
        let row = DesktopHistoryRowSummary(polished, locale: locale, timeZone: utc) { names[$0] ?? $0 }
        XCTAssertEqual(row.id, polished.id)
        XCTAssertEqual(row.audioLength, "24.00")
        XCTAssertEqual(row.cost, "$0.02")
        XCTAssertEqual(row.preview, "Could we move the catch-up to Friday? Thanks.")
        XCTAssertEqual(row.models, "OpenAI Whisper • Post-processing: GPT-5 mini")
        XCTAssertEqual(row.context, "Profile: Email")
        XCTAssertEqual(row.tone, .normal)

        var synced = DesktopRecordingStore.Record(
            syncedID: UUID(), createdAt: Date(), modelIdentifier: "openai/whisper-1", originPlatform: "macos"
        )
        synced.result = record().result
        XCTAssertEqual(DesktopHistoryRowSummary(synced, locale: locale).context, "From your Mac")
    }

    func testRowSummary_marksFailuresPendingAndSilentRecordings() {
        let failed = DesktopHistoryRowSummary(record(text: nil, failure: "The key was rejected."), locale: locale)
        XCTAssertEqual(failed.tone, .failed)
        XCTAssertEqual(failed.preview, "The key was rejected.")
        XCTAssertNil(failed.audioLength)
        XCTAssertNil(failed.cost)

        let pending = DesktopHistoryRowSummary(record(text: nil), locale: locale)
        XCTAssertEqual(pending.tone, .pending)
        XCTAssertEqual(pending.preview, "Recording saved; awaiting transcription.")

        let silent = DesktopHistoryRowSummary(record(text: ""), locale: locale)
        XCTAssertEqual(silent.tone, .normal)
        XCTAssertEqual(silent.preview, "No speech was detected.")

        let long = DesktopHistoryRowSummary(record(text: String(repeating: "word ", count: 100)), locale: locale)
        XCTAssertEqual(long.preview.count, DesktopHistoryRowSummary.previewLimit)
        XCTAssertTrue(long.preview.hasSuffix("…"))
    }
}
