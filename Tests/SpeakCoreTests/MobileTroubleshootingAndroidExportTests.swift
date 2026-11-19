import Foundation
import XCTest

@testable import SpeakCore

/// Android's Troubleshooting section reads a committed JSON asset; this keeps it identical to the shared rules.
final class MobileTroubleshootingAndroidExportTests: XCTestCase {
    private var assetURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("android/app/src/main/assets/troubleshooting.json")
    }

    func testAndroidAssetMatchesRules() throws {
        let expected = try MobileTroubleshootingAndroidExport.json()
        if ProcessInfo.processInfo.environment["UPDATE_TROUBLESHOOTING_ANDROID"] == "1" {
            try expected.write(to: assetURL)
        }
        let committed = try Data(contentsOf: assetURL)
        XCTAssertEqual(
            committed, expected,
            "android/app/src/main/assets/troubleshooting.json is stale. Regenerate with scripts/update-android-assets"
        )
    }

    func testKeyRules_nameTheProviderThroughThePlaceholder() throws {
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: MobileTroubleshootingAndroidExport.json()) as? [String: Any]
        )
        let checks = try XCTUnwrap(document["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.compactMap { $0["id"] as? String }, MobileTroubleshooting.Check.allCases.map(\.rawValue))
        let key = try XCTUnwrap(checks.first { $0["id"] as? String == "transcription-api-key" })
        let states = try XCTUnwrap(key["states"] as? [String: [String: Any]])
        XCTAssertEqual(Set(states.keys), ["present", "missing", "rejected", "unreadable"])
        let missing = try XCTUnwrap(states["missing"]?["title"] as? String)
        XCTAssertTrue(missing.contains(MobileTroubleshootingAndroidExport.providerPlaceholder), missing)
    }
}
