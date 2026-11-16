import Foundation
import XCTest

@testable import SpeakCore

/// Android's Downloaded models list reads a committed JSON asset; this keeps it identical to
/// `WhisperCppModels`.
final class WhisperCppAndroidExportTests: XCTestCase {
    private var assetURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("android/app/src/main/assets/whisper_models.json")
    }

    func testAndroidAssetMatchesPins() throws {
        let expected = try WhisperCppAndroidExport.json()
        if ProcessInfo.processInfo.environment["UPDATE_WHISPER_MODELS_ANDROID"] == "1" {
            try expected.write(to: assetURL)
        }
        let committed = try Data(contentsOf: assetURL)
        XCTAssertEqual(
            committed, expected,
            "android/app/src/main/assets/whisper_models.json is stale. Regenerate with "
                + "scripts/update-android-assets"
        )
    }

    func testEveryPinIsExportedOnceWithItsIntegrityFields() throws {
        let object = try JSONSerialization.jsonObject(with: WhisperCppAndroidExport.json()) as? [String: Any]
        XCTAssertEqual(object?["revision"] as? String, WhisperCppModels.revision)
        let models = try XCTUnwrap(object?["models"] as? [[String: Any]])
        XCTAssertEqual(models.compactMap { $0["catalogId"] as? String }, WhisperCppModels.all.map(\.catalogueID))
        for model in models {
            let url = try XCTUnwrap(model["url"] as? String)
            XCTAssertTrue(url.contains("/resolve/\(WhisperCppModels.revision)/"), url)
            XCTAssertEqual((model["sha256"] as? String)?.count, 64)
            XCTAssertGreaterThan(model["bytes"] as? Int64 ?? 0, 0)
            XCTAssertEqual(model["license"] as? String, "MIT")
            XCTAssertEqual(model["allowedHosts"] as? [String], [".hf.co", ".huggingface.co", "huggingface.co"])
        }
    }

    func testOnlyLargeV3TurboNeedsAMemoryFloor() {
        let gated = WhisperCppModels.all.filter {
            WhisperCppAndroidExport.minimumDeviceMemoryBytes(forCatalogueID: $0.catalogueID) != nil
        }
        XCTAssertEqual(gated.map(\.catalogueID), ["local/whisperkit/large-v3-turbo"])
        let floors = WhisperCppAndroidExport.memoryFloors.keys
        XCTAssertTrue(floors.allSatisfy { WhisperCppModels.model(forCatalogueID: $0) != nil })
    }
}
