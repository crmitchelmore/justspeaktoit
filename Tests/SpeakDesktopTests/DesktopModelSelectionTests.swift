import Foundation
import XCTest
@testable import SpeakCore
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

    /// Every identifier the shared catalogue retires, including ones retired
    /// later, resumes as its successor in the active slot and its mode's slot.
    func testEveryRetiredIdentifierResumesAsItsSharedSuccessor() {
        for (retired, successor) in ModelCatalog.liveTranscriptionSuccessors {
            XCTAssertEqual(migrate(retired, live: retired),
                           DesktopModelSelection(model: successor, batchModel: nil, liveModel: successor), retired)
        }
        for (retired, successor) in ModelCatalog.batchTranscriptionSuccessors {
            XCTAssertEqual(migrate(retired, batch: retired),
                           DesktopModelSelection(model: successor, batchModel: successor, liveModel: nil), retired)
        }
    }

    /// Current entries are never retired: every route this host implements,
    /// including routes added later, resumes exactly as saved.
    func testEveryDesktopRouteResumesUnchanged() {
        for option in DesktopTranscription.batchModels {
            XCTAssertEqual(migrate(option.id, batch: option.id),
                           DesktopModelSelection(model: option.id, batchModel: option.id, liveModel: nil), option.id)
        }
        for option in DesktopLiveTranscription.liveModels {
            XCTAssertEqual(migrate(option.id, live: option.id),
                           DesktopModelSelection(model: option.id, batchModel: nil, liveModel: option.id), option.id)
        }
    }

    /// Reported regression (justspeaktoit-iif.3.1): Deepgram Flux is current,
    /// so it stays active and remembered while the retired Nova-2 stream moves.
    func testDeepgramFluxResumesWhileNova2MovesToNova3() throws {
        let batch = try XCTUnwrap(DesktopTranscription.batchModels.first?.id)
        for flux in ["deepgram/flux-general-en-streaming", "deepgram/flux-general-multi-streaming"] {
            XCTAssertEqual(migrate(flux, batch: batch, live: flux),
                           DesktopModelSelection(model: flux, batchModel: batch, liveModel: flux))
            XCTAssertEqual(migrate(batch, batch: batch, live: flux),
                           DesktopModelSelection(model: batch, batchModel: batch, liveModel: flux))
        }
        XCTAssertEqual(migrate("deepgram/nova-2-streaming", batch: batch, live: "deepgram/nova-2-streaming"),
                       DesktopModelSelection(model: "deepgram/nova-3-streaming", batchModel: batch,
                                             liveModel: "deepgram/nova-3-streaming"))
    }

    /// A discovered OpenRouter selection is not retired, so it stays routable
    /// even when the cached discovery no longer lists it.
    func testDiscoveredOpenRouterSelectionResumesAsSaved() {
        let discovered = OpenRouterTranscriptionSelection.identifier(for: "vendor/not-cached")
        XCTAssertEqual(migrate(discovered, batch: discovered),
                       DesktopModelSelection(model: discovered, batchModel: discovered, liveModel: nil))
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
