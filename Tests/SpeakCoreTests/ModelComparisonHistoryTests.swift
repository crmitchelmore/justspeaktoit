import Foundation
import XCTest

@testable import SpeakCore

final class ModelComparisonHistoryTests: XCTestCase {
    private func makeRound(mode: ModelComparisonInputMode = .streaming) -> ModelComparisonRound {
        let good = ModelComparisonEntry(
            modelID: "deepgram/nova-3-streaming", modelDisplayName: "Nova-3", providerDisplayName: "Deepgram",
            transcript: " Hello world. ", timeToFirstPartialMs: 900, timeToFinalMs: 250,
            estimatedCostUSD: Decimal(string: "0.0012")
        )
        let failed = ModelComparisonEntry(
            modelID: "meta/muse-voice-transcribe-1.0-streaming", modelDisplayName: "Muse Voice",
            providerDisplayName: "Meta",
            errorDescription: "Meta Model API rejected the API key. Check it in Settings."
        )
        return ModelComparisonRound(
            createdAt: Date(timeIntervalSince1970: 1_000), inputMode: mode,
            sample: ModelComparisonSample(name: "capture.wav", contentHash: nil, durationSeconds: 4.5),
            language: "en", originPlatform: "macos", entries: [good, failed], blindOrder: [failed.id, good.id]
        )
    }

    func testItems_oneTaggedItemPerLaneWithModelCostAndLatency() throws {
        let round = makeRound()
        let savedAt = Date(timeIntervalSince1970: 1_010)
        let items = ModelComparisonHistory.items(for: round, savedAt: savedAt)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
        XCTAssertTrue(items.allSatisfy(ModelComparisonHistory.isComparisonItem))
        XCTAssertTrue(items.allSatisfy { $0.trigger.outputMethod == .none })

        let good = try XCTUnwrap(items.first { $0.modelsUsed == ["deepgram/nova-3-streaming"] })
        XCTAssertEqual(good.rawTranscription, "Hello world.")
        XCTAssertNil(good.postProcessedTranscription)
        XCTAssertEqual(good.modelUsages, [ApplicationModelUsage(modelIdentifier: "deepgram/nova-3-streaming",
                                                                 phase: .transcriptionLive)])
        XCTAssertEqual(good.cost?.total, Decimal(string: "0.0012"))
        XCTAssertEqual(good.cost?.currency, "USD")
        XCTAssertEqual(good.latency?.firstPartialMs, 900)
        XCTAssertEqual(good.latency?.stopToFinalMs, 250)
        XCTAssertEqual(good.recordingDuration, 4.5)
        XCTAssertEqual(good.createdAt, round.createdAt)
        XCTAssertTrue(good.errors.isEmpty)
        XCTAssertTrue(good.events.contains { $0.kind == .transcriptionReceived })
        XCTAssertTrue(good.events.allSatisfy { !$0.description.contains("Hello") }, "Events never copy transcript")
    }

    func testItems_failedLaneKeepsItsErrorAndNoTranscript() throws {
        let items = ModelComparisonHistory.items(for: makeRound())
        let failed = try XCTUnwrap(items.first { $0.modelsUsed == ["meta/muse-voice-transcribe-1.0-streaming"] })

        XCTAssertNil(failed.rawTranscription)
        XCTAssertNil(failed.cost)
        XCTAssertNil(failed.latency)
        XCTAssertEqual(failed.errors.map(\.message), ["Meta Model API rejected the API key. Check it in Settings."])
        XCTAssertEqual(failed.errors.first?.phase, .transcription)
        XCTAssertTrue(failed.events.contains { $0.kind == .error })
    }

    func testItems_fileRoundsRecordBatchUsage() {
        let items = ModelComparisonHistory.items(for: makeRound(mode: .file))
        XCTAssertTrue(items.allSatisfy { $0.modelUsages.first?.phase == .transcriptionBatch })
    }

    func testItems_roundTripThroughTheExistingHistorySchema() throws {
        let items = ModelComparisonHistory.items(for: makeRound())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([ApplicationHistoryItem].self, from: encoder.encode(items))
        XCTAssertEqual(decoded.map(\.id), items.map(\.id))
        XCTAssertTrue(decoded.allSatisfy(ModelComparisonHistory.isComparisonItem))
    }

    func testScoreboard_reportsTheLatestFailureText() throws {
        var older = makeRound()
        older.entries[1].errorDescription = "Old failure"
        let template = makeRound()
        let newer = ModelComparisonRound(
            createdAt: Date(timeIntervalSince1970: 2_000), inputMode: .streaming, sample: template.sample,
            language: "en", originPlatform: "macos", entries: template.entries, blindOrder: template.blindOrder
        )
        let scores = ModelComparisonScoreboard.scores(for: [older, newer])
        let meta = try XCTUnwrap(scores.first { $0.modelID.hasPrefix("meta/") })
        XCTAssertEqual(meta.failures, 2)
        XCTAssertEqual(meta.latestFailure, "Meta Model API rejected the API key. Check it in Settings.")
        XCTAssertNil(scores.first { $0.modelID.hasPrefix("deepgram/") }?.latestFailure)
    }
}
