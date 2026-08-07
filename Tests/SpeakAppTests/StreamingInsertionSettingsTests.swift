import XCTest
import SpeakCore

@testable import SpeakApp

final class StreamingInsertionSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    @MainActor
    override func setUp() {
        super.setUp()
        suiteName = "com.speakapp.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testStreamingInsertion_DefaultsToOff() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.streamingInsertionEnabled)
    }

    @MainActor
    func testStreamingInsertion_PersistsWhenToggled() {
        let settings = AppSettings(defaults: defaults)
        settings.streamingInsertionEnabled = true
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.streamingInsertionEnabled)
    }

    private func makeTarget(bundleIdentifier: String?) -> TextOutputTarget {
        TextOutputTarget(
            processIdentifier: 123,
            applicationName: "Test App",
            bundleIdentifier: bundleIdentifier,
            applicationLaunchDate: nil,
            focusedElement: nil
        )
    }

    func testAllowlist_AcceptsKnownGoodTargets() {
        for bundleID in [
            "com.apple.TextEdit",
            "com.apple.Notes",
            "com.tinyspeck.slackmacgap",
            "com.microsoft.VSCode",
            "com.apple.Safari",
            "com.google.Chrome"
        ] {
            XCTAssertTrue(
                StreamingInsertionAllowlist.allows(self.makeTarget(bundleIdentifier: bundleID)),
                "expected allowlist to accept \(bundleID)"
            )
        }
    }

    func testAllowlist_RejectsUnknownOrMissingTargets() {
        XCTAssertFalse(StreamingInsertionAllowlist.allows(nil))
        XCTAssertFalse(StreamingInsertionAllowlist.allows(self.makeTarget(bundleIdentifier: nil)))
        XCTAssertFalse(
            StreamingInsertionAllowlist.allows(self.makeTarget(bundleIdentifier: "com.apple.mail"))
        )
        XCTAssertFalse(
            StreamingInsertionAllowlist.allows(self.makeTarget(bundleIdentifier: "org.mozilla.firefox"))
        )
    }
}
