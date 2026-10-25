import XCTest
@testable import SpeakApp
import SpeakCore

/// The macOS side of the batch additions: the registry has to hand a batch
/// model to the provider that owns it, the provider has to reject models it
/// does not own, and adding batch options must not disturb the live entries
/// a user may already have selected.
final class BatchTranscriptionProviderRoutingTests: XCTestCase {

    func testRegisteredInstanceControlsKnownBatchAndLiveCredentialOwnership() async {
        let whisper = "openai/whisper-1"
        let live = "openai/gpt-live-transcribe-streaming"
        let registry = TranscriptionProviderRegistry(providers: [
            "openai": RoutingProvider(id: "replacement", models: [live], credential: "fixture.key")
        ])
        let missingBatch = await registry.provider(forModel: whisper)
        XCTAssertNil(missingBatch, "Catalogue ownership must not widen the registered instance")
        let selected = await registry.provider(forModel: " \n" + live + "\t")
        XCTAssertEqual(selected?.metadata.id, "replacement")
        XCTAssertEqual(selected?.metadata.apiKeyIdentifier, "fixture.key")
        let requiresKey = await registry.requiresAPIKey(for: live)
        XCTAssertTrue(requiresKey, "A non-batch lookup still owns the live credential")
    }

    func testEmptyRegisteredCatalogueRetainsPrefixOwnershipWithoutCaseFolding() async {
        let registry = TranscriptionProviderRegistry(providers: [
            "openai": RoutingProvider(id: "empty", models: [], credential: "fixture.key")
        ])
        for model in ["openai/whisper-1", "openai/unknown", "/openai//unknown", "openai"] {
            let selected = await registry.provider(forModel: " \n" + model + "\t")
            XCTAssertEqual(selected?.metadata.id, "empty", model)
        }
        for model in ["OpenAI/whisper-1", "other/openai/whisper-1", "", " / "] {
            let selected = await registry.provider(forModel: model)
            XCTAssertNil(selected, model)
        }
    }

    func testAlibabaRegisteredInstanceRetainsInvalidSelectionOwnership() async {
        let registry = TranscriptionProviderRegistry(providers: [
            "alibaba": RoutingProvider(id: "alibaba", models: ["alibaba/one"], credential: "fixture.key")
        ])
        for model in ["alibaba/unknown", "/alibaba//unknown", "alibaba", AlibabaSpeechModels.funLive] {
            let selected = await registry.provider(forModel: model)
            XCTAssertEqual(selected?.metadata.id, "alibaba", model)
        }
    }

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

private struct RoutingProvider: TranscriptionProvider {
    let metadata: TranscriptionProviderMetadata
    let models: [String]

    init(id: String, models: [String], credential: String) {
        self.metadata = .init(id: id, displayName: id, apiKeyIdentifier: credential)
        self.models = models
    }

    func supportedModels() -> [ModelCatalog.Option] {
        models.map { .init(id: $0, displayName: $0, description: "Routing fixture") }
    }

    func requiresAPIKey(for model: String) -> Bool { true }

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        XCTFail("Routing must not validate credentials")
        return .failure(message: "Unexpected validation")
    }

    func transcribeFile(at url: URL, apiKey: String, model: String, language: String?) async throws
        -> TranscriptionResult {
        XCTFail("Routing must not start a provider")
        throw TranscriptionProviderError.invalidResponse
    }
}
