import XCTest
@testable import SpeakApp
import SpeakCore

/// The macOS side of the batch additions: the registry has to hand a batch
/// model to the provider that owns it, the provider has to reject models it
/// does not own, and adding batch options must not disturb the live entries
/// a user may already have selected.
final class BatchTranscriptionProviderRoutingTests: XCTestCase {

    func testGladiaBatchRoutesToGladiaAndKeepsItsLiveEntry() async throws {
        let provider = await TranscriptionProviderRegistry.shared
            .provider(forModel: GladiaBatchClient.catalogID)
        XCTAssertEqual(provider?.metadata.id, "gladia")
        let ids = try XCTUnwrap(provider?.supportedModels().map(\.id))
        XCTAssertTrue(ids.contains(GladiaBatchClient.catalogID))
        XCTAssertTrue(ids.contains("gladia/solaria-1-streaming"))
    }

    func testSpeechmaticsBatchTiersRouteToSpeechmaticsAndKeepTheLiveEntry() async throws {
        for id in SpeechmaticsBatchClient.catalogIDs {
            let provider = await TranscriptionProviderRegistry.shared.provider(forModel: id)
            XCTAssertEqual(provider?.metadata.id, "speechmatics", "for \(id)")
        }
        let provider = await TranscriptionProviderRegistry.shared
            .provider(forModel: SpeechmaticsBatchClient.enhancedCatalogID)
        let ids = try XCTUnwrap(provider?.supportedModels().map(\.id))
        XCTAssertTrue(Set(ids).isSuperset(of: SpeechmaticsBatchClient.catalogIDs))
        XCTAssertTrue(ids.contains("speechmatics/enhanced-streaming"))
    }

    /// The streaming identifiers are not file-transcription models, so asking a
    /// provider to transcribe a file with one must fail before any upload.
    func testStreamingIdentifiersAreStillRejectedByTheFilePath() async throws {
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        try Data([0, 1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        await assertThrows {
            _ = try await GladiaTranscriptionProvider().transcribeFile(
                at: audio, apiKey: "key", model: "gladia/solaria-1-streaming", language: nil)
        }
        await assertThrows {
            _ = try await SpeechmaticsTranscriptionProvider().transcribeFile(
                at: audio, apiKey: "key", model: "speechmatics/enhanced-streaming", language: nil)
        }
    }

    func testTheNewBatchEntriesOnlyAppearInTheBatchPicker() {
        let batchIDs = Set(ModelCatalog.batchTranscription.map(\.id))
        let liveIDs = Set(ModelCatalog.liveTranscription.map(\.id))
        let added = SpeechmaticsBatchClient.catalogIDs.union([GladiaBatchClient.catalogID])
        XCTAssertTrue(batchIDs.isSuperset(of: added))
        XCTAssertTrue(liveIDs.isDisjoint(with: added))
        // Friendly names carry the provider and the tier so History stays readable.
        for id in added {
            let name = ModelCatalog.batchTranscription.first { $0.id == id }?.displayName ?? ""
            XCTAssertTrue(name.hasSuffix("(Batch)"), "\(id) -> \(name)")
        }
    }

    private func assertThrows(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected an error", file: file, line: line)
        } catch {}
    }
}
