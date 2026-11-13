import Foundation
import XCTest

@testable import SpeakCore

/// Android's tip jar reads a committed JSON asset; this keeps it identical to `TipCatalog`.
final class TipCatalogAndroidExportTests: XCTestCase {
    private var assetURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("android/app/src/main/assets/tip_catalog.json")
    }

    func testAndroidAssetMatchesCatalogue() throws {
        let expected = try TipCatalogAndroidExport.json()
        if ProcessInfo.processInfo.environment["UPDATE_TIP_CATALOG_ANDROID"] == "1" {
            try expected.write(to: assetURL)
        }
        let committed = try Data(contentsOf: assetURL)
        XCTAssertEqual(
            committed, expected,
            "android/app/src/main/assets/tip_catalog.json is stale. Regenerate with "
                + "UPDATE_TIP_CATALOG_ANDROID=1 swift test --filter TipCatalogAndroidExportTests"
        )
    }

    func testProductIDs_matchTheStoreKitConfiguration() throws {
        let storekit = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Configuration.storekit")
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: storekit)) as? [String: Any]
        let products = try XCTUnwrap(document?["products"] as? [[String: Any]])
        let storeIDs = products.compactMap { $0["productID"] as? String }
        XCTAssertEqual(Set(storeIDs), Set(TipCatalog.productIDs))
        XCTAssertEqual(TipCatalog.productIDs.count, Set(TipCatalog.productIDs).count)
    }

    func testEmoji_fallsBackForUnknownProducts() {
        XCTAssertEqual(TipCatalog.emoji(for: "com.justspeaktoit.tip.medium"), "🍔")
        XCTAssertEqual(TipCatalog.emoji(for: "com.example.unknown"), "💝")
    }
}
