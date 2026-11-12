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

    func testAppStorePlist_omitsProductAnalyticsConfiguration() {
        XCTAssertNil(appStorePlist["PostHogProjectKey"])
        XCTAssertNil(appStorePlist["PostHogHost"])
    }

    func testAppStorePlist_declaresLocalNetworkUsage() {
        let value = appStorePlist["NSLocalNetworkUsageDescription"] as? String
        let expected = "Just Speak to It uses your local network to connect iPhone and Mac "
            + "for Send to Mac transcription transfer."
        XCTAssertEqual(value, expected)
    }

    func testAppStorePlist_declaresBonjourService() {
        let services = appStorePlist["NSBonjourServices"] as? [String]
        XCTAssertEqual(services, ["_speaktransport._tcp"])
    }

    func testAppStorePlist_matchesDirectPlistExceptSparkleKeys() {
        let sparkleKeys = [
            "SUEnableAutomaticChecks",
            "SUFeedURL",
            "SUPublicEDKey",
            "SUScheduledCheckInterval",
            // The headless self-update smoke mode and the loopback-only ATS
            // exemption it needs exist for Sparkle alone, so they stay off the
            // App Store build, which updates through the store.
            "SpeakSparkleSmokeSupported",
            "NSAppTransportSecurity"
        ]
        var directWithoutSparkle = directPlist!
        sparkleKeys.forEach { directWithoutSparkle.removeValue(forKey: $0) }
        directWithoutSparkle.removeValue(forKey: "PostHogProjectKey")
        directWithoutSparkle.removeValue(forKey: "PostHogHost")
        directWithoutSparkle["CFBundleDisplayName"] = "Just Speak to It (App Store)"
        directWithoutSparkle["CFBundleName"] = "Just Speak to It App Store"
        directWithoutSparkle["SpeakDistributionChannel"] = "appStore"

        XCTAssertEqual(
            appStorePlist as NSDictionary,
            directWithoutSparkle as NSDictionary,
            "Distribution plists should differ only by Sparkle metadata and channel-specific identity"
        )
    }

    func testDistributionPlists_declareTheirRuntimeChannel() {
        XCTAssertEqual(directPlist["SpeakDistributionChannel"] as? String, "direct")
        XCTAssertEqual(appStorePlist["SpeakDistributionChannel"] as? String, "appStore")
    }

    func testDistributionNames_allowSideBySideInstallation() {
        XCTAssertEqual(directPlist["CFBundleDisplayName"] as? String, "Just Speak to It")
        XCTAssertEqual(appStorePlist["CFBundleDisplayName"] as? String, "Just Speak to It (App Store)")
        XCTAssertEqual(directPlist["CFBundleName"] as? String, "Just Speak to It")
        XCTAssertEqual(appStorePlist["CFBundleName"] as? String, "Just Speak to It App Store")
    }

    func testRecordingPurposeStringsDescribeCloudAndLocalProcessing() {
        for info in [directPlist!, appStorePlist!] {
            let microphone = info["NSMicrophoneUsageDescription"] as? String ?? ""
            XCTAssertTrue(microphone.contains("provider you choose in Settings"))
            XCTAssertTrue(microphone.contains("on-device model"))
            let speech = info["NSSpeechRecognitionUsageDescription"] as? String ?? ""
            XCTAssertTrue(speech.contains("processed by Apple"))
        }
    }

    func testMacPrivacyManifestsKeepProductAnalyticsOutOfTheStore() throws {
        let store = try Self.loadPlist(at: "Sources/SpeakApp/Resources/AppStore/PrivacyInfo.xcprivacy")
        let direct = try Self.loadPlist(at: "Sources/SpeakApp/Resources/Direct/PrivacyInfo.xcprivacy")
        let storeEntries = try XCTUnwrap(store["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let directEntries = try XCTUnwrap(direct["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let baseline = Set([
            "NSPrivacyCollectedDataTypeAudioData", "NSPrivacyCollectedDataTypeOtherUserContent",
            "NSPrivacyCollectedDataTypeCrashData", "NSPrivacyCollectedDataTypePerformanceData",
            "NSPrivacyCollectedDataTypeOtherDiagnosticData", "NSPrivacyCollectedDataTypeDeviceID"
        ])
        XCTAssertEqual(Set(storeEntries.compactMap { $0["NSPrivacyCollectedDataType"] as? String }), baseline)
        for type in ["NSPrivacyCollectedDataTypeProductInteraction", "NSPrivacyCollectedDataTypeDeviceID"] {
            let entry = try XCTUnwrap(directEntries.first { $0["NSPrivacyCollectedDataType"] as? String == type })
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            let purposes = try XCTUnwrap(entry["NSPrivacyCollectedDataTypePurposes"] as? [String])
            XCTAssertTrue(purposes.contains("NSPrivacyCollectedDataTypePurposeAnalytics"))
        }
        for entry in storeEntries {
            let purposes = try XCTUnwrap(entry["NSPrivacyCollectedDataTypePurposes"] as? [String])
            XCTAssertEqual(purposes, ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
            if !["NSPrivacyCollectedDataTypeAudioData", "NSPrivacyCollectedDataTypeOtherUserContent"]
                .contains(entry["NSPrivacyCollectedDataType"] as? String ?? "") {
                XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
            }
        }
        XCTAssertEqual(store["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(direct["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(
            store["NSPrivacyAccessedAPITypes"] as? NSArray,
            direct["NSPrivacyAccessedAPITypes"] as? NSArray
        )
    }

    private static func loadPlist(at path: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let plist = parsed as? [String: Any] else {
            throw NSError(
                domain: "AppStoreInfoPlistTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected \(path) to parse as a dictionary"]
            )
        }
        return plist
    }
}
