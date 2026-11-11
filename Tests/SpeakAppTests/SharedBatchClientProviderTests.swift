import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

final class SharedBatchClientProviderTests: XCTestCase {
    func testForwardingAdapters_matchTheirBatchClientContract() {
        assertForwards(GroqTranscriptionProvider())
        assertForwards(ElevenLabsTranscriptionProvider())
        assertForwards(AssemblyAITranscriptionProvider())
        assertForwards(DeepgramTranscriptionProvider())
        assertForwards(RevAITranscriptionProvider())
        assertForwards(OpenAITranscriptionProvider())
        assertForwards(MistralTranscriptionProvider())
        assertForwards(ModulateTranscriptionProvider())
    }

    func testSoniox_addsLiveOptionsAheadOfTheBatchClientModels() {
        let provider = SonioxTranscriptionProvider()
        let batchIDs = provider.batchClient.supportedModels().map(\.id)
        XCTAssertEqual(provider.metadata.id, provider.batchClient.metadata.id)
        XCTAssertEqual(Array(provider.supportedModels().map(\.id).suffix(batchIDs.count)), batchIDs)
    }

    func testAppleAudioDuration_assetThrowsAndResolvedFallsBackToZeroForUnreadableFile() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).m4a")
        do {
            _ = try await AppleAudioDuration.asset(missing)
            XCTFail("Expected the asset probe to throw for a missing file")
        } catch {}
        let resolved = await AppleAudioDuration.resolved(missing)
        XCTAssertEqual(resolved, 0)
    }

    private func assertForwards<Provider: SharedBatchClientProvider>(
        _ provider: Provider, file: StaticString = #filePath, line: UInt = #line
    ) {
        let client = provider.batchClient
        XCTAssertEqual(provider.metadata.id, client.metadata.id, file: file, line: line)
        XCTAssertEqual(provider.metadata.apiKeyIdentifier, client.metadata.apiKeyIdentifier, file: file, line: line)
        let models = client.supportedModels()
        XCTAssertFalse(models.isEmpty, "\(client.metadata.id) exposes no models", file: file, line: line)
        XCTAssertEqual(provider.supportedModels(), models, file: file, line: line)
        for model in models {
            XCTAssertEqual(
                provider.requiresAPIKey(for: model.id), client.requiresAPIKey(for: model.id), file: file, line: line
            )
        }
    }
}
