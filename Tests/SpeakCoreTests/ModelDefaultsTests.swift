import XCTest

@testable import SpeakCore

/// Defaults and migrations that keep both platforms off retired models.
final class ModelDefaultsTests: XCTestCase {
    func testBatchTranscription_migratesRetiredGemini20Selections() {
        let ids = Set(ModelCatalog.batchTranscription.map(\.id))
        for retired in ["google/gemini-2.0-flash-001", "google/gemini-2.0-flash-lite-001"] {
            XCTAssertFalse(ids.contains(retired), "\(retired) is retired and must leave the catalogue")
            XCTAssertEqual(
                ModelCatalog.normalizedBatchTranscriptionModel(retired),
                ModelCatalog.defaultBatchTranscriptionModel
            )
        }
    }

    func testFastTextDefault_isFastCloudPostProcessingModel() {
        let option = ModelCatalog.cloudPostProcessing.first { $0.id == ModelCatalog.defaultFastTextModel }
        XCTAssertNotNil(option, "The fast text default must be a selectable cloud post-processing model")
        XCTAssertTrue(option?.tags.contains(.fast) == true)
    }

    func testResolvedPostProcessingModel_fallsBackOnlyWhenEmpty() {
        for empty in [nil, "", "  \n"] {
            XCTAssertEqual(
                ModelCatalog.resolvedPostProcessingModel(empty),
                ModelCatalog.defaultPostProcessingModel
            )
        }
        XCTAssertEqual(
            ModelCatalog.resolvedPostProcessingModel(" custom/model "),
            "custom/model"
        )
    }
}
