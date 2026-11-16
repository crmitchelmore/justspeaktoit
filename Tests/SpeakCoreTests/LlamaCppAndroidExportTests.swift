import Foundation
import XCTest

@testable import SpeakCore

/// Android's downloaded cleanup models read a committed JSON asset; this keeps it identical to
/// `ModelCatalog.localPostProcessing` and its `LlamaCppModels` pins.
final class LlamaCppAndroidExportTests: XCTestCase {
    private var assetURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("android/app/src/main/assets/cleanup_models.json")
    }

    func testAndroidAssetMatchesPins() throws {
        let expected = try LlamaCppAndroidExport.json()
        if ProcessInfo.processInfo.environment["UPDATE_CLEANUP_MODELS_ANDROID"] == "1" {
            try expected.write(to: assetURL)
        }
        let committed = try Data(contentsOf: assetURL)
        XCTAssertEqual(
            committed, expected,
            "android/app/src/main/assets/cleanup_models.json is stale. Regenerate with "
                + "scripts/update-android-assets"
        )
    }

    func testEveryCatalogueModelIsPinnedOnceWithItsCatalogueFile() {
        XCTAssertEqual(LlamaCppModels.all.map(\.catalogueID), ModelCatalog.localPostProcessing.map(\.id))
        for (pinned, entry) in zip(LlamaCppModels.all, ModelCatalog.localPostProcessing) {
            XCTAssertEqual(pinned.displayName, entry.displayName)
            XCTAssertEqual(pinned.repository, entry.repoID)
            XCTAssertEqual(pinned.artifact.filename, entry.filename)
            XCTAssertEqual(entry.backend, .llamaCppGGUF)
            XCTAssertEqual(pinned.storageIdentifier, "local/llamacpp/sha256/" + pinned.artifact.sha256)
        }
    }

    func testExportCarriesIntegrityFieldsForEveryPin() throws {
        let object = try JSONSerialization.jsonObject(with: LlamaCppAndroidExport.json()) as? [String: Any]
        let models = try XCTUnwrap(object?["models"] as? [[String: Any]])
        XCTAssertEqual(models.compactMap { $0["catalogId"] as? String }, LlamaCppModels.all.map(\.catalogueID))
        for (model, pinned) in zip(models, LlamaCppModels.all) {
            let url = try XCTUnwrap(model["url"] as? String)
            XCTAssertEqual(pinned.revision.count, 40)
            XCTAssertTrue(url.hasPrefix("https://huggingface.co/\(pinned.repository)/resolve/\(pinned.revision)/"))
            XCTAssertEqual((model["sha256"] as? String)?.count, 64)
            XCTAssertEqual(model["sha256"] as? String, (model["sha256"] as? String)?.lowercased())
            XCTAssertGreaterThan(model["bytes"] as? Int64 ?? 0, 0)
            XCTAssertEqual(model["license"] as? String, "Apache-2.0")
            XCTAssertEqual(model["allowedHosts"] as? [String], [".hf.co", ".huggingface.co", "huggingface.co"])
        }
    }

    func testOnlyQwen3OnePointSevenNeedsAMemoryFloor() {
        let gated = LlamaCppModels.all.filter {
            LlamaCppAndroidExport.minimumDeviceMemoryBytes(forCatalogueID: $0.catalogueID) != nil
        }
        XCTAssertEqual(gated.map(\.catalogueID), ["local/post-processing/qwen3-1.7b-q4"])
        XCTAssertTrue(LlamaCppAndroidExport.memoryFloors.keys.allSatisfy {
            LlamaCppModels.model(forCatalogueID: $0) != nil
        })
    }
}
