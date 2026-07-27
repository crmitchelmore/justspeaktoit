import XCTest

@testable import SpeakCore

final class AssemblyAIModelCatalogTests: XCTestCase {
    func testUniversal35Pro_replacesUniversal3AcrossCatalogues() throws {
        let live = try XCTUnwrap(ModelCatalog.liveTranscription.first {
            $0.id == AssemblyAIModels.universal35ProStreamingID
        })
        let batch = try XCTUnwrap(ModelCatalog.batchTranscription.first {
            $0.id == AssemblyAIModels.universal35ProBatchID
        })

        XCTAssertEqual(live.displayName, "AssemblyAI Universal-3.5 Pro (Streaming)")
        XCTAssertEqual(batch.displayName, "AssemblyAI Universal-3.5 Pro")
        XCTAssertFalse(ModelCatalog.liveTranscription.contains { $0.id == "assemblyai/u3-rt-pro-streaming" })
        XCTAssertFalse(ModelCatalog.batchTranscription.contains { $0.id == "assemblyai/universal-3-pro" })
    }

    func testUniversal3Selections_migrateToUniversal35Pro() {
        XCTAssertEqual(
            ModelCatalog.normalizedLiveTranscriptionModel("assemblyai/u3-rt-pro-streaming"),
            AssemblyAIModels.universal35ProStreamingID
        )
        XCTAssertEqual(
            ModelCatalog.normalizedLiveTranscriptionModel("assemblyai/universal-streaming-multilingual"),
            AssemblyAIModels.universal35ProStreamingID
        )
        XCTAssertEqual(
            ModelCatalog.normalizedBatchTranscriptionModel("assemblyai/universal-3-pro"),
            AssemblyAIModels.universal35ProBatchID
        )
    }
}
