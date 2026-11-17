import Foundation
import XCTest

@testable import SpeakCore

final class SpeechSessionRecordHistoryTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_700_000_000)

    func testInit_prefersRawTranscriptAndFallsBackToProcessedWhenRawIsBlank() throws {
        let raw = try XCTUnwrap(record(raw: "um raw words", processed: "Raw words."))
        XCTAssertEqual(raw.text, "um raw words")
        let fallback = try XCTUnwrap(record(raw: "  \n", processed: "Processed words."))
        XCTAssertEqual(fallback.text, "Processed words.")
    }

    func testInit_skipsEntriesWithoutText() {
        XCTAssertNil(record(raw: nil, processed: nil))
        XCTAssertNil(record(raw: " ", processed: "\n"))
    }

    func testInit_takesDurationFromRecordingTimestampsWhenNoneWasStored() throws {
        let timestamps = ApplicationPhaseTimestamps(
            recordingStarted: created, recordingEnded: created.addingTimeInterval(12.5)
        )
        XCTAssertEqual(try XCTUnwrap(record(raw: "hello", duration: 0, timestamps: timestamps)).duration, 12.5)
        XCTAssertEqual(try XCTUnwrap(record(raw: "hello", duration: 4, timestamps: timestamps)).duration, 4)
        XCTAssertEqual(try XCTUnwrap(record(raw: "hello", duration: 0)).duration, 0)
    }

    func testInitHistoryRecord_mapsTheSharedRecordUsingTheTranscriptionModel() throws {
        let history = HistoryRecord(
            createdAt: created,
            modelsUsed: ["openai/gpt-transcribe", "openrouter/cleanup"],
            modelUsages: [
                ApplicationModelUsage(modelIdentifier: "openrouter/cleanup", phase: .postProcessing),
                ApplicationModelUsage(modelIdentifier: "openai/gpt-transcribe", phase: .transcriptionBatch)
            ],
            rawTranscription: "you know it works",
            postProcessedTranscription: "It works.",
            recordingDuration: 30,
            trigger: ApplicationHistoryTrigger(
                gesture: .uiButton, hotKeyDescription: "", outputMethod: .clipboard, destinationApplication: "Notes"
            ),
            originPlatform: "ios"
        )
        let session = try XCTUnwrap(SpeechSessionRecord(historyRecord: history))
        XCTAssertEqual(session.id, history.id)
        XCTAssertEqual(session.startedAt, created)
        XCTAssertEqual(session.text, "you know it works")
        XCTAssertEqual(session.duration, 30)
        XCTAssertEqual(session.destinationApplication, "Notes")
        XCTAssertEqual(session.modelIdentifier, "openai/gpt-transcribe")
    }

    @MainActor
    func testModel_refreshSummarisesRecordsAndPersistsTheAggregate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = SpeechInsightsModel.storageURL(inSupportDirectory: directory)
        XCTAssertEqual(url.lastPathComponent, "speech-insights-aggregate.json")
        let records = try [
            XCTUnwrap(record(raw: "um ship the build", duration: 30)),
            XCTUnwrap(SpeechSessionRecord(
                historyID: UUID(), createdAt: created, rawTranscription: "you know ship it",
                postProcessedTranscription: nil, recordingDuration: 20, phaseTimestamps: nil
            ))
        ]

        let model = SpeechInsightsModel(storageURL: url, now: { self.created })
        model.refresh(records: records)
        await model.waitForPendingRefresh()
        XCTAssertEqual(model.summary?.sessionsAnalyzed, 2)
        XCTAssertEqual(model.summary?.funStats.totalWordsAllTime, 8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let reloaded = SpeechInsightsModel(storageURL: url, now: { self.created })
        reloaded.refresh(records: Array(records.prefix(1)))
        await reloaded.waitForPendingRefresh()
        XCTAssertEqual(reloaded.summary?.sessionsAnalyzed, 1)
    }

    private func record(
        raw: String?,
        processed: String? = nil,
        duration: TimeInterval = 10,
        timestamps: ApplicationPhaseTimestamps? = nil
    ) -> SpeechSessionRecord? {
        SpeechSessionRecord(
            historyID: UUID(),
            createdAt: created,
            rawTranscription: raw,
            postProcessedTranscription: processed,
            recordingDuration: duration,
            phaseTimestamps: timestamps
        )
    }
}
