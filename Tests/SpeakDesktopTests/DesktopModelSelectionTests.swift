import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class DesktopModelSelectionTests: XCTestCase {
    private let liveIDs = Set(DesktopLiveTranscription.liveModels.map(\.id))

    private func migrate(_ model: String?, batch: String? = nil, live: String? = nil,
                         liveEnabled: Bool = true) -> DesktopModelSelection {
        let liveIDs = liveEnabled ? self.liveIDs : []
        return DesktopModelSelection.migrated(
            model: model, batchModel: batch, liveModel: live,
            isLive: { liveIDs.contains($0) },
            isBatch: { DesktopTranscription.provider(for: $0) != nil }
        )
    }

    func testRetiredBatchSelectionsMoveToTheSameSuccessorAsApple() {
        for legacy in ["elevenlabs/scribe_v1", "elevenlabs/scribe_v1_experimental"] {
            XCTAssertEqual(migrate(legacy), DesktopModelSelection(
                model: ModelCatalog.elevenLabsScribeV2BatchID,
                batchModel: ModelCatalog.elevenLabsScribeV2BatchID, liveModel: nil
            ))
        }
        let assembly = migrate("assemblyai/universal-3-pro", batch: "assemblyai/universal-3-pro")
        XCTAssertEqual(assembly.model, AssemblyAIModels.universal35ProBatchID)
        XCTAssertEqual(assembly.batchModel, AssemblyAIModels.universal35ProBatchID)
        for identifier in [assembly.model, ModelCatalog.elevenLabsScribeV2BatchID] {
            XCTAssertEqual(ModelCatalog.normalizedBatchTranscriptionModel(identifier), identifier)
            XCTAssertNotNil(DesktopTranscription.provider(for: identifier), identifier)
        }
    }

    func testRetiredLiveSelectionsMoveToTheSameSuccessorAsApple() throws {
        let successor = AssemblyAIModels.universal35ProStreamingID
        try XCTSkipUnless(liveIDs.contains(successor), "AssemblyAI live is not in the desktop projection")
        let batch = try XCTUnwrap(DesktopTranscription.batchModels.first?.id)
        let active = migrate("assemblyai/u3-rt-pro-streaming", batch: batch, live: "u3-rt-pro-streaming")
        XCTAssertEqual(active, DesktopModelSelection(model: successor, batchModel: batch, liveModel: successor))
        let remembered = migrate(batch, batch: batch, live: "assemblyai/u3-rt-pro")
        XCTAssertEqual(remembered, DesktopModelSelection(model: batch, batchModel: batch, liveModel: successor))
    }

    func testLegacySettingsWithOnlyAnActiveModelFillItsModeSlot() throws {
        let batch = try XCTUnwrap(DesktopTranscription.batchModels.last?.id)
        XCTAssertEqual(migrate(batch), DesktopModelSelection(model: batch, batchModel: batch, liveModel: nil))
        let live = try XCTUnwrap(DesktopLiveTranscription.liveModels.first?.id)
        XCTAssertEqual(migrate(live), DesktopModelSelection(model: live, batchModel: nil, liveModel: live))
    }

    func testActiveModelWinsOverAStaleSlotOfTheSameMode() throws {
        let batches = DesktopTranscription.batchModels.map(\.id)
        let lives = DesktopLiveTranscription.liveModels.map(\.id)
        try XCTSkipUnless(batches.count > 1 && lives.count > 1)
        XCTAssertEqual(migrate(batches[0], batch: batches[1], live: lives[1]),
                       DesktopModelSelection(model: batches[0], batchModel: batches[0], liveModel: lives[1]))
        XCTAssertEqual(migrate(lives[0], batch: batches[1], live: lives[1]),
                       DesktopModelSelection(model: lives[0], batchModel: batches[1], liveModel: lives[0]))
    }

    func testSlotsHoldOnlyRunnableModelsOfTheirOwnMode() throws {
        let batch = try XCTUnwrap(DesktopTranscription.batchModels.first?.id)
        let live = try XCTUnwrap(DesktopLiveTranscription.liveModels.first?.id)
        let swapped = migrate(batch, batch: live, live: batch)
        XCTAssertEqual(swapped, DesktopModelSelection(model: batch, batchModel: batch, liveModel: nil))
        let unknown = migrate(batch, batch: "vendor/not-a-model", live: "vendor/not-live")
        XCTAssertEqual(unknown, DesktopModelSelection(model: batch, batchModel: batch, liveModel: nil))
    }

    func testUnusableActiveModelKeepsTheUsersRememberedChoiceBeforeTheDefault() throws {
        let batch = try XCTUnwrap(DesktopTranscription.batchModels.last?.id)
        let live = try XCTUnwrap(DesktopLiveTranscription.liveModels.first?.id)
        XCTAssertNotEqual(batch, ModelCatalog.defaultBatchTranscriptionModel)
        // Live transport not qualified on this host: its live choice cannot run.
        XCTAssertEqual(migrate(live, batch: batch, live: live, liveEnabled: false),
                       DesktopModelSelection(model: batch, batchModel: batch, liveModel: nil))
        XCTAssertEqual(migrate("local/whisper/unsupported", live: live),
                       DesktopModelSelection(model: live, batchModel: nil, liveModel: live))
    }

    func testMissingOrUnusableSelectionFallsBackToTheCanonicalDefault() {
        let fallback = DesktopModelSelection(
            model: ModelCatalog.defaultBatchTranscriptionModel,
            batchModel: ModelCatalog.defaultBatchTranscriptionModel, liveModel: nil
        )
        XCTAssertEqual(migrate(nil), fallback)
        XCTAssertEqual(migrate("  "), fallback)
        XCTAssertEqual(migrate("openrouter/whisper-large-v3"), fallback, "retired without successor")
        XCTAssertEqual(migrate("apple/local/SFSpeechRecognizer"), fallback)
    }

    func testMigrationIsIdempotent() throws {
        let inputs: [DesktopModelSelection] = [
            .init(model: "elevenlabs/scribe_v1", batchModel: nil, liveModel: "assemblyai/u3-rt-pro"),
            .init(model: "", batchModel: nil, liveModel: nil),
            .init(model: DesktopLiveTranscription.liveModels.first?.id ?? "", batchModel: "assemblyai/universal-3-pro",
                  liveModel: nil)
        ]
        for input in inputs {
            let once = migrate(input.model, batch: input.batchModel, live: input.liveModel)
            XCTAssertEqual(migrate(once.model, batch: once.batchModel, live: once.liveModel), once)
        }
    }
}
