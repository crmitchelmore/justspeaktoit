import Foundation
import XCTest
@testable import SpeakApp

final class SelfUpdateConfigurationTests: XCTestCase {
    private let key = Data(repeating: 1, count: 32).base64EncodedString()

    func testPreviewWithoutFeedCannotUpdate() {
        XCTAssertFalse(SelfUpdateConfiguration.isConfigured(info: ["SUEnableAutomaticChecks": false]))
    }

    func testPublishedBuildCanUpdateWithAutomaticChecksDisabled() {
        XCTAssertTrue(SelfUpdateConfiguration.isConfigured(info: [
            "SUFeedURL": "https://example.com/alpha/appcast.xml",
            "SUPublicEDKey": key, "SUEnableAutomaticChecks": false
        ]))
    }

    func testMissingOrMalformedFeedAndKeyCannotUpdate() {
        for feed in ["", "appcast.xml", "file:///tmp/appcast.xml", "https://", "http://example.com/appcast.xml"] {
            XCTAssertFalse(SelfUpdateConfiguration.isConfigured(info: [
                "SUFeedURL": feed, "SUPublicEDKey": key
            ]), feed)
        }
        for invalidKey in ["", "invalid", Data(repeating: 1, count: 31).base64EncodedString()] {
            XCTAssertFalse(SelfUpdateConfiguration.isConfigured(info: [
                "SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": invalidKey
            ]))
        }
    }
}
