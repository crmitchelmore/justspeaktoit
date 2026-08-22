import XCTest

@testable import SpeakApp

/// An arm64-only update may only be offered to a process running natively on
/// Apple Silicon; every other configuration keeps the universal feed (#774).
final class UpdateFeedSelectionTests: XCTestCase {
    private let legacy = UpdateFeedSelection.legacyFeedURL
    private let appleSilicon = UpdateFeedSelection.appleSiliconFeedURL

    func testNativeAppleSilicon_followsTheArm64Feed() {
        XCTAssertEqual(
            UpdateFeedSelection.feedURL(configuredFeedURL: legacy, machineArchitecture: "arm64", isTranslated: false),
            appleSilicon
        )
    }

    func testIntel_keepsTheUniversalFeed() {
        XCTAssertEqual(
            UpdateFeedSelection.feedURL(configuredFeedURL: legacy, machineArchitecture: "x86_64", isTranslated: false),
            legacy
        )
    }

    func testRosettaTranslatedProcess_keepsTheUniversalFeed() {
        // A universal build running as x86_64 under Rosetta reports arm64 hardware
        // but must not be handed an arm64-only update it cannot verify it can run.
        XCTAssertEqual(
            UpdateFeedSelection.feedURL(configuredFeedURL: legacy, machineArchitecture: "arm64", isTranslated: true),
            legacy
        )
    }

    func testCustomOrMissingFeed_isLeftUntouched() {
        let custom = "https://example.com/test-appcast.xml"
        XCTAssertEqual(
            UpdateFeedSelection.feedURL(configuredFeedURL: custom, machineArchitecture: "arm64", isTranslated: false),
            custom
        )
        XCTAssertNil(
            UpdateFeedSelection.feedURL(configuredFeedURL: nil, machineArchitecture: "arm64", isTranslated: false)
        )
    }

    func testMachineArchitecture_isAKnownValue() {
        XCTAssertTrue(["arm64", "x86_64"].contains(UpdateFeedSelection.machineArchitecture))
    }

    func testShippedInfoPlist_keepsTheUniversalFeedAsTheFailSafeDefault() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plist = try String(contentsOf: root.appendingPathComponent("Config/AppInfo.plist"), encoding: .utf8)
        XCTAssertTrue(
            plist.contains("<string>\(legacy)</string>"),
            "If feed selection ever fails, an arm64 build must fall back to a feed every Mac can run"
        )
    }
}
