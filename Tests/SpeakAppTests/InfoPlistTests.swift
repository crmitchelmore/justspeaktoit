import XCTest

@testable import SpeakApp

/// Verifies that Info.plist contains all required keys for the app to
/// launch correctly, receive updates via Sparkle, and request system permissions.
///
/// These tests parse the actual plist file used by the build system,
/// catching typos and missing keys before they reach users.
final class InfoPlistTests: XCTestCase {

    private var plist: [String: Any]!
    private let plistPath = "Config/AppInfo.plist"

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: plistPath)
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        plist = parsed as? [String: Any]
        XCTAssertNotNil(plist, "AppInfo.plist should parse as a dictionary")
    }

    // MARK: - Required Bundle Keys

    func testBundleIdentifier_isPresent() {
        let value = plist["CFBundleIdentifier"] as? String
        XCTAssertNotNil(value, "CFBundleIdentifier must be present")
        // It uses $(PRODUCT_BUNDLE_IDENTIFIER) which is resolved at build time
    }

    func testBundleVersion_isPresent() {
        let value = plist["CFBundleVersion"] as? String
        XCTAssertNotNil(value, "CFBundleVersion must be present")
        XCTAssertFalse(value?.isEmpty ?? true, "CFBundleVersion must not be empty")
    }

    func testBundleShortVersion_isPresent() {
        let value = plist["CFBundleShortVersionString"] as? String
        XCTAssertNotNil(value, "CFBundleShortVersionString must be present")
        XCTAssertFalse(value?.isEmpty ?? true)
    }

    func testMinimumSystemVersion_matchesPlatformRequirement() {
        let value = plist["LSMinimumSystemVersion"] as? String
        XCTAssertEqual(value, "14.0",
            "LSMinimumSystemVersion should match the macOS 14 platform requirement in Package.swift")
    }

    // MARK: - Sparkle Update Configuration

    func testSparkleFeedURL_isValidHTTPS() {
        let value = plist["SUFeedURL"] as? String
        XCTAssertNotNil(value, "SUFeedURL must be present for Sparkle updates")

        guard let urlString = value else { return }
        XCTAssertTrue(urlString.hasPrefix("https://"),
            "SUFeedURL must use HTTPS for security: got '\(urlString)'")

        let url = URL(string: urlString)
        XCTAssertNotNil(url, "SUFeedURL must be a valid URL: '\(urlString)'")
    }

    func testSparklePublicKey_isPresent() {
        let value = plist["SUPublicEDKey"] as? String
        XCTAssertNotNil(value, "SUPublicEDKey must be present for Sparkle signature verification")
        XCTAssertFalse(value?.isEmpty ?? true, "SUPublicEDKey must not be empty")
        // EdDSA public keys are base64-encoded, typically 44 chars
        XCTAssertGreaterThan(value?.count ?? 0, 20,
            "SUPublicEDKey looks too short to be a valid EdDSA public key")
    }

    func testSparkleAutoCheckEnabled() {
        let value = plist["SUEnableAutomaticChecks"] as? Bool
        XCTAssertEqual(value, true,
            "Automatic update checks should be enabled by default")
    }

    // MARK: - Privacy Usage Descriptions

    func testMicrophoneUsageDescription_isPresent() {
        let value = plist["NSMicrophoneUsageDescription"] as? String
        XCTAssertNotNil(value, "NSMicrophoneUsageDescription is REQUIRED for microphone access")
        XCTAssertFalse(value?.isEmpty ?? true)
    }

    func testSpeechRecognitionUsageDescription_isPresent() {
        let value = plist["NSSpeechRecognitionUsageDescription"] as? String
        XCTAssertNotNil(value, "NSSpeechRecognitionUsageDescription is required for speech recognition")
        XCTAssertFalse(value?.isEmpty ?? true)
    }

    func testAccessibilityUsageDescription_isPresent() {
        let value = plist["NSAccessibilityUsageDescription"] as? String
        XCTAssertNotNil(value,
            "NSAccessibilityUsageDescription is required for accessibility text insertion")
        XCTAssertFalse(value?.isEmpty ?? true)
    }

    func testInputMonitoringUsageDescription_isPresent() {
        let value = plist["NSInputMonitoringUsageDescription"] as? String
        XCTAssertNotNil(value,
            "NSInputMonitoringUsageDescription is required for global hotkey detection")
        XCTAssertFalse(value?.isEmpty ?? true)
    }

    // MARK: - App Configuration

    func testPrincipalClass_isNSApplication() {
        let value = plist["NSPrincipalClass"] as? String
        XCTAssertEqual(value, "NSApplication",
            "macOS app must use NSApplication as principal class")
    }

    func testAppCategory_isProductivity() {
        let value = plist["LSApplicationCategoryType"] as? String
        XCTAssertEqual(value, "public.app-category.productivity")
    }
}
