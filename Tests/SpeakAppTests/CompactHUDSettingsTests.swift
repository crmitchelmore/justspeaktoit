import XCTest
import SpeakCore

@testable import SpeakApp

final class CompactHUDSettingsTests: XCTestCase {
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
    func testCompactHUD_DefaultsToOff() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.showCompactHUD)
    }

    @MainActor
    func testCompactHUD_PersistsWhenToggled() {
        let settings = AppSettings(defaults: defaults)
        settings.showCompactHUD = true
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.showCompactHUD)
    }

    /// The live-transcript preference is independent state: enabling the compact
    /// HUD ignores it at render time but must not silently clear it, so it is
    /// restored if the compact HUD is switched back off.
    @MainActor
    func testCompactHUD_DoesNotClearLiveTranscriptPreference() {
        let settings = AppSettings(defaults: defaults)
        settings.showLiveTranscriptInHUD = true
        settings.showCompactHUD = true
        XCTAssertTrue(settings.showLiveTranscriptInHUD)
    }

    func testElapsedLabel_UnderOneMinute_IsSecondsWithSuffix() {
        XCTAssertEqual(CompactHUDContent.elapsedLabel(for: 0), "0s")
        XCTAssertEqual(CompactHUDContent.elapsedLabel(for: 7.78), "7s")
        XCTAssertEqual(CompactHUDContent.elapsedLabel(for: 59.9), "59s")
    }

    func testElapsedLabel_OneMinuteAndOver_IsMinutesColonSeconds() {
        XCTAssertEqual(CompactHUDContent.elapsedLabel(for: 60), "1:00s")
        XCTAssertEqual(CompactHUDContent.elapsedLabel(for: 83), "1:23s")
        XCTAssertEqual(CompactHUDContent.elapsedLabel(for: 600), "10:00s")
    }

    func testElapsedLabel_NegativeElapsed_ClampsToZero() {
        XCTAssertEqual(CompactHUDContent.elapsedLabel(for: -5), "0s")
    }
}
