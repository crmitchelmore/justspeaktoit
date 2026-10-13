import XCTest

@testable import SpeakCore

final class AssemblyAIModelCatalogTests: XCTestCase {
    func testUniversal36Pro_updatesStreamingButPreservesBatch35() throws {
        let live = try XCTUnwrap(ModelCatalog.liveTranscription.first {
            $0.id == AssemblyAIModels.universal36ProStreamingID
        })
        let batch = try XCTUnwrap(ModelCatalog.batchTranscription.first {
            $0.id == AssemblyAIModels.universal35ProBatchID
        })

        XCTAssertEqual(live.displayName, "AssemblyAI Universal-3.6 Pro (Streaming)")
        XCTAssertEqual(batch.displayName, "AssemblyAI Universal-3.5 Pro")
        XCTAssertFalse(ModelCatalog.liveTranscription.contains { $0.id == "assemblyai/u3-rt-pro-streaming" })
        XCTAssertFalse(ModelCatalog.batchTranscription.contains { $0.id == "assemblyai/universal-3-pro" })
    }

    func testUniversal3Selections_migrateSeparatelyByMode() {
        XCTAssertEqual(
            ModelCatalog.normalizedLiveTranscriptionModel("assemblyai/u3-rt-pro-streaming"),
            AssemblyAIModels.universal36ProStreamingID
        )
        XCTAssertEqual(
            ModelCatalog.normalizedLiveTranscriptionModel("assemblyai/universal-streaming-multilingual"),
            AssemblyAIModels.universal36ProStreamingID
        )
        XCTAssertEqual(
            ModelCatalog.normalizedBatchTranscriptionModel("assemblyai/universal-3-pro"),
            AssemblyAIModels.universal35ProBatchID
        )
        XCTAssertEqual(
            ModelCatalog.normalizedLiveTranscriptionModel(AssemblyAIModels.universal35ProStreamingID),
            AssemblyAIModels.universal36ProStreamingID
        )
        XCTAssertEqual(
            ModelCatalog.normalizedBatchTranscriptionModel(AssemblyAIModels.universal35ProBatchID),
            AssemblyAIModels.universal35ProBatchID
        )
        XCTAssertFalse(ModelCatalog.batchTranscription.contains { $0.id == "assemblyai/universal-3-6-pro" })
    }
}
