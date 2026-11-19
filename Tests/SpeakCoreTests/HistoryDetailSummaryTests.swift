import Foundation
import SpeakCore
import XCTest

final class HistoryDetailSummaryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testSummary_listsTriggerModelsTimingsAndCostWithoutTranscript() {
        let record = HistoryRecord(
            modelUsages: [
                .init(modelIdentifier: "synthetic/polish", phase: .postProcessing),
                .init(modelIdentifier: "deepgram/nova-3", phase: .transcriptionLive),
                .init(modelIdentifier: "deepgram/nova-3", phase: .transcriptionLive)
            ],
            rawTranscription: "PRIVATE raw", postProcessedTranscription: "PRIVATE polished",
            recordingDuration: 4,
            cost: .init(total: Decimal(string: "0.12")!, currency: "USD"),
            phaseTimestamps: .init(
                recordingStarted: start, recordingEnded: start.addingTimeInterval(4),
                transcriptionStarted: start.addingTimeInterval(4), transcriptionEnded: start.addingTimeInterval(4.8),
                postProcessingStarted: start.addingTimeInterval(4.8),
                postProcessingEnded: start.addingTimeInterval(7.2)
            ),
            trigger: .init(gesture: .automation, hotKeyDescription: "Shortcut", outputMethod: .none)
        )

        let rows = HistoryDetailSummary(record: record).rows
        XCTAssertEqual(rows.map(\.id), [
            "trigger", "model-live", "model-post-processing", "recording",
            "transcript-latency", "post-processing-latency", "total", "cost"
        ])
        let values = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.value) })
        XCTAssertEqual(values["trigger"], "Automation · Shortcut")
        XCTAssertEqual(values["model-live"], ModelCatalog.friendlyName(for: "deepgram/nova-3"))
        XCTAssertEqual(values["transcript-latency"], "800 ms after stop")
        XCTAssertEqual(values["post-processing-latency"], "2.4 s")
        XCTAssertEqual(values["total"], "7.2 s")
        XCTAssertTrue(values["cost"]?.contains("0.12") == true)
        XCTAssertFalse(rows.contains { $0.value.contains("PRIVATE") })
    }

    func testSummary_fallsBackToFriendlyRecordedModelForLegacyEntries() {
        let record = HistoryRecord(recordingDuration: 0, model: "deepgram/nova-3", originPlatform: "ios")
        XCTAssertEqual(HistoryDetailSummary(record: record).rows, [
            .init(id: "model", title: "Model", value: ModelCatalog.friendlyName(for: "deepgram/nova-3"))
        ])
    }

    func testFormatCurrency_keepsSubCentCostsVisible() {
        func usd(_ text: String) -> String {
            HistoryDetailFormatting.formatCurrency(Decimal(string: text)!, currency: "USD")
        }
        XCTAssertTrue(usd("0.0042").contains("0.0042"))
        XCTAssertTrue(usd("0.005").contains("0.005"))
        XCTAssertFalse(usd("0.005").contains("0.0050"))
        XCTAssertTrue(usd("0.00001").hasPrefix("< "))
        XCTAssertTrue(usd("0.00001").contains("0.0001"))
        XCTAssertTrue(usd("0.12").contains("0.12"))
        XCTAssertFalse(usd("0.12").contains("0.120"))
        XCTAssertTrue(usd("0").contains("0.00"))
    }

    func testFormatCurrency_appliesTheGivenLocale() {
        func format(_ text: String, _ identifier: String) -> String {
            HistoryDetailFormatting.formatCurrency(
                Decimal(string: text)!, currency: "USD", locale: Locale(identifier: identifier)
            )
        }
        XCTAssertEqual(format("0.0042", "en_US"), "$0.0042")
        XCTAssertEqual(format("0.0042", "en_GB"), "US$0.0042")
        XCTAssertEqual(format("1.5", "en_US"), "$1.50")
    }

    func testTrigger_labelsComparisonButtonWithoutHotKeyOrRawName() {
        let comparison = ApplicationHistoryTrigger(
            gesture: .uiButton, hotKeyDescription: ModelComparisonHistory.triggerDescription, outputMethod: .none
        )
        XCTAssertEqual(comparison.gestureLabel, "Button")
        XCTAssertFalse(comparison.isHotKeyGesture)
        XCTAssertEqual(comparison.historySummary, "Button · Compare Models")
        let hold = ApplicationHistoryTrigger(gesture: .hold, hotKeyDescription: "Right Option", outputMethod: .none)
        XCTAssertTrue(hold.isHotKeyGesture)
    }

    func testFormatLatency_coversEachScaleAndRejectsNegative() {
        XCTAssertEqual(HistoryDetailFormatting.formatLatency(0.85), "850 ms")
        XCTAssertEqual(HistoryDetailFormatting.formatLatency(2.4), "2.4 s")
        XCTAssertEqual(HistoryDetailFormatting.formatLatency(65), "1m 05s")
        XCTAssertNil(HistoryDetailFormatting.formatLatency(-1))
    }

    func testTimeline_usesRelativeDurationsAndMarksFailedPhase() {
        let times = ApplicationPhaseTimestamps(
            transcriptionStarted: start, transcriptionEnded: start.addingTimeInterval(1),
            postProcessingStarted: start.addingTimeInterval(1), postProcessingEnded: start.addingTimeInterval(3)
        )
        let events = HistoryDetailFormatting.diagnosticTimeline(
            times, failedPhases: [.postProcessing], isLive: false
        )
        XCTAssertEqual(events.map(\.stage), [.request, .postProcessing])
        XCTAssertEqual(events.map(\.elapsedMilliseconds), [1_000, 2_000])
        XCTAssertEqual(events.map(\.outcome), [.succeeded, .failed])
        XCTAssertTrue(HistoryDetailFormatting.diagnosticTimeline(nil, isLive: true).isEmpty)
    }

    func testIOSLegacyDecode_readsSessionDetails() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","createdAt":0,"transcription":"t","model":"m",
         "duration":1,"wordCount":1,
         "modelUsages":[{"modelIdentifier":"deepgram/nova-3","phase":"batch"}],
         "phaseTimestamps":{"recordingStarted":0,"recordingEnded":2},
         "trigger":{"gesture":"uiButton","hotKeyDescription":"In-app button","outputMethod":"none"}}
        """
        let record = try JSONDecoder().decode(HistoryRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.modelUsages.map(\.phase), [.transcriptionBatch])
        XCTAssertEqual(record.phaseTimestamps?.recordingEnded, Date(timeIntervalSinceReferenceDate: 2))
        XCTAssertEqual(record.trigger?.gesture, .uiButton)
    }
}
