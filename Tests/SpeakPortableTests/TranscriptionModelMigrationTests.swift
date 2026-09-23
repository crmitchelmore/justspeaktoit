import XCTest
@testable import SpeakCore

/// Retired-identifier migration has one shared definition. These invariants
/// keep it from ever moving a current catalogue entry, including entries added
/// later, and make every retired identifier land on a current entry of its mode.
final class TranscriptionModelMigrationTests: XCTestCase {
    private let live = Set(ModelCatalog.liveTranscription.map(\.id))
    private let batch = Set(ModelCatalog.batchTranscription.map(\.id))

    func testEveryCatalogueEntry_isKeptBySharedMigration() {
        for identifier in live {
            XCTAssertEqual(ModelCatalog.normalizedLiveTranscriptionModel(identifier), identifier)
        }
        for identifier in batch {
            XCTAssertEqual(ModelCatalog.normalizedBatchTranscriptionModel(identifier), identifier)
        }
    }

    /// Each retired identifier has exactly one successor, which is a current
    /// entry of the same mode, so migration never chains or crosses modes.
    func testRetiredIdentifiers_moveToACurrentEntryOfTheSameMode() {
        let retiredLive = ModelCatalog.liveTranscriptionSuccessors
        let retiredBatch = ModelCatalog.batchTranscriptionSuccessors
        XCTAssertTrue(Set(retiredLive.keys).isDisjoint(with: retiredBatch.keys))
        for (retired, successor) in retiredLive {
            XCTAssertFalse(live.contains(retired) || batch.contains(retired), retired)
            XCTAssertTrue(live.contains(successor), retired)
            XCTAssertEqual(ModelCatalog.normalizedLiveTranscriptionModel(retired), successor)
        }
        for (retired, successor) in retiredBatch {
            XCTAssertFalse(live.contains(retired) || batch.contains(retired), retired)
            XCTAssertTrue(batch.contains(successor), retired)
            XCTAssertEqual(ModelCatalog.normalizedBatchTranscriptionModel(retired), successor)
        }
    }

    /// Reported regression (justspeaktoit-iif.3.1): only Deepgram's retired
    /// Nova-2 stream moves to Nova-3; both current Flux streams stay chosen.
    func testDeepgramNova2Stream_movesToNova3WhileFluxStays() {
        XCTAssertEqual(
            ModelCatalog.normalizedLiveTranscriptionModel("deepgram/nova-2-streaming"),
            "deepgram/nova-3-streaming"
        )
        for flux in ["deepgram/flux-general-en-streaming", "deepgram/flux-general-multi-streaming"] {
            XCTAssertTrue(live.contains(flux), flux)
            XCTAssertEqual(ModelCatalog.normalizedLiveTranscriptionModel(flux), flux)
        }
    }

    /// Custom models, including ones under a provider that has catalogue
    /// entries, and discovered OpenRouter selections are never retired.
    func testCustomAndDiscoveredIdentifiers_areKeptAsSaved() {
        for identifier in ["deepgram/custom-streaming", "assemblyai/custom-streaming", "acme/realtime-v1"] {
            XCTAssertEqual(ModelCatalog.normalizedLiveTranscriptionModel(identifier), identifier)
        }
        let discovered = OpenRouterTranscriptionSelection.identifier(for: "vendor/model")
        for identifier in ["deepgram/custom", "assemblyai/custom", discovered] {
            XCTAssertEqual(ModelCatalog.normalizedBatchTranscriptionModel(identifier), identifier)
        }
        XCTAssertEqual(
            ModelCatalog.normalizedLiveTranscriptionModel(" deepgram/nova-2-streaming "),
            "deepgram/nova-3-streaming"
        )
        XCTAssertEqual(
            ModelCatalog.normalizedBatchTranscriptionModel(" elevenlabs/scribe_v1 "),
            ModelCatalog.elevenLabsScribeV2BatchID
        )
    }

    /// The remembered remote slot is sanitised by the same rule, so switching
    /// back to remote restores a retired stream's successor, or Flux as chosen.
    func testRememberedRemoteModel_followsTheSharedMigration() {
        for (retired, successor) in ModelCatalog.liveTranscriptionSuccessors {
            XCTAssertEqual(LiveTranscriptionSelection(remoteModel: retired).remoteModel, successor, retired)
        }
        for flux in ["deepgram/flux-general-en-streaming", "deepgram/flux-general-multi-streaming"] {
            XCTAssertEqual(LiveTranscriptionSelection(remoteModel: flux).remoteModel, flux)
        }
    }
}
