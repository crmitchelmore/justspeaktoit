import XCTest

final class AppStoreInfoPlistTests: XCTestCase {

    private var directPlist: [String: Any]!
    private var appStorePlist: [String: Any]!

    override func setUpWithError() throws {
        directPlist = try Self.loadPlist(at: "Config/AppInfo.plist")
        appStorePlist = try Self.loadPlist(at: "Config/AppInfo.AppStore.plist")
    }

    func testAppStorePlist_omitsSparkleUpdateKeys() {
        let sparkleKeys = [
            "SUEnableAutomaticChecks",
            "SUFeedURL",
            "SUPublicEDKey",
            "SUScheduledCheckInterval"
        ]

        for key in sparkleKeys {
            XCTAssertNil(appStorePlist[key], "App Store plist must not ship Sparkle key \(key)")
        }
    }

    func testAppStorePlist_declaresLocalNetworkUsage() {
        let value = appStorePlist["NSLocalNetworkUsageDescription"] as? String
        let expected =
            "Just Speak to It uses your local network to connect iPhone and Mac "
            + "for Send to Mac transcription transfer."
        XCTAssertEqual(value, expected)
    }

    func testAppStorePlist_declaresBonjourService() {
        let services = appStorePlist["NSBonjourServices"] as? [String]
        XCTAssertEqual(services, ["_speaktransport._tcp", "_speaktransport._udp"])
    }

    func testAppStorePlist_matchesDirectPlistExceptSparkleKeys() {
        let sparkleKeys = [
            "SUEnableAutomaticChecks",
            "SUFeedURL",
            "SUPublicEDKey",
            "SUScheduledCheckInterval"
        ]
        var directWithoutSparkle = directPlist!
        sparkleKeys.forEach { directWithoutSparkle.removeValue(forKey: $0) }

        XCTAssertEqual(
            appStorePlist as NSDictionary,
            directWithoutSparkle as NSDictionary,
            "Distribution plists should differ only by the direct build's Sparkle metadata"
        )
    }

    private static func loadPlist(at path: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let plist = parsed as? [String: Any] else {
            throw XCTSkip("Expected \(path) to parse as a dictionary")
        }
        return plist
    }
}
