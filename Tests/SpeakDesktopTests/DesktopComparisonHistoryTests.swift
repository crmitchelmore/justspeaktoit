import Foundation
import XCTest
import SpeakCore
import SpeakDesktop

final class DesktopComparisonHistoryTests: XCTestCase {
    func testRecords_oneLocalTaggedRecordPerLaneWithCostLatencyAndFailure() throws {
        let good = ModelComparisonEntry(
            modelID: "deepgram/nova-3-streaming", modelDisplayName: "Nova-3", providerDisplayName: "Deepgram",
            transcript: "Hello world.", timeToFirstPartialMs: 900, timeToFinalMs: 250,
            estimatedCostUSD: Decimal(string: "0.0012")
        )
        let failed = ModelComparisonEntry(
            modelID: "soniox/stt-rt-v5-streaming", modelDisplayName: "Soniox", providerDisplayName: "Soniox",
            errorDescription: "The model did not finish within its time limit."
        )
        let round = ModelComparisonRound(
            inputMode: .streaming,
            sample: ModelComparisonSample(name: "capture.wav", contentHash: nil, durationSeconds: 3),
            language: nil, originPlatform: "windows", entries: [good, failed], blindOrder: [good.id, failed.id]
        )
        let records = DesktopComparisonHistory.records(for: round)

        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy(DesktopComparisonHistory.isComparisonRecord))
        XCTAssertTrue(records.allSatisfy { !$0.isSyncedCopy && $0.recordedDuration == 3 })
        let success = try XCTUnwrap(records.first { $0.modelIdentifier == good.modelID })
        XCTAssertEqual(success.result?.text, "Hello world.")
        XCTAssertEqual(success.recordingCost?.total, Decimal(string: "0.0012"))
        XCTAssertNil(success.failure)
        XCTAssertEqual(success.profileNotes?.contains("First partial: 900 ms"), true)
        XCTAssertEqual(success.profileNotes?.contains("Stop to final: 250 ms"), true)
        let failure = try XCTUnwrap(records.first { $0.modelIdentifier == failed.modelID })
        XCTAssertNil(failure.result)
        XCTAssertEqual(failure.failure, "The model did not finish within its time limit.")
    }
}
