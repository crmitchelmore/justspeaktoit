import Foundation
import XCTest

@testable import SpeakCore

/// The Android app reads the settings search catalogue from a committed JSON asset;
/// this keeps it identical to `SettingsSearchCatalog`.
final class SettingsSearchAndroidExportTests: XCTestCase {
    private var assetURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("android/app/src/main/assets/settings_search.json")
    }

    func testAndroidAssetMatchesCatalogue() throws {
        let expected = try SettingsSearchAndroidExport.json()
        if ProcessInfo.processInfo.environment["UPDATE_SETTINGS_SEARCH_ANDROID"] == "1" {
            try FileManager.default.createDirectory(
                at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try expected.write(to: assetURL)
        }
        let committed = try Data(contentsOf: assetURL)
        XCTAssertEqual(
            committed, expected,
            "android/app/src/main/assets/settings_search.json is stale. Regenerate with "
                + "UPDATE_SETTINGS_SEARCH_ANDROID=1 swift test --filter SettingsSearchAndroidExportTests"
        )
    }

    func testAndroidEntriesAreExported() throws {
        let object = try JSONSerialization.jsonObject(with: SettingsSearchAndroidExport.json()) as? [String: Any]
        let entries = object?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, SettingsSearchCatalog.entries(for: .android).count)
        XCTAssertFalse((object?["synonyms"] as? [[String]] ?? []).isEmpty)
    }
}
