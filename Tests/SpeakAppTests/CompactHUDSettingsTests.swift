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

    /// The live-transcript preference is independent state: toggling the compact
    /// HUD leaves it untouched, so each can be set without disturbing the other.
    @MainActor
    func testCompactHUD_DoesNotClearLiveTranscriptPreference() {
        let settings = AppSettings(defaults: defaults)
        settings.showLiveTranscriptInHUD = true
        settings.showCompactHUD = true
        XCTAssertTrue(settings.showLiveTranscriptInHUD)
    }

    /// The compact HUD draws the scrolling transcript line only in the
    /// live-transcript phases (recording and voice-edit) and only when the
    /// live-transcript preference is on, so the line can be turned off
    /// independently while the compact HUD stays on. Mirrors the full HUD.
    func testCompactHUD_ShowsLiveTranscriptOnlyInLiveTranscriptPhasesWhenEnabled() {
        // On in the live-transcript phases.
        XCTAssertTrue(
            CompactHUDContent.showsLiveTranscript(phase: .recording, showLiveTranscriptInHUD: true)
        )
        XCTAssertTrue(
            CompactHUDContent.showsLiveTranscript(phase: .editing, showLiveTranscriptInHUD: true)
        )
        // Off when the preference is off, even in a live-transcript phase.
        XCTAssertFalse(
            CompactHUDContent.showsLiveTranscript(phase: .recording, showLiveTranscriptInHUD: false)
        )
        XCTAssertFalse(
            CompactHUDContent.showsLiveTranscript(phase: .editing, showLiveTranscriptInHUD: false)
        )
        // Off in non-live-transcript phases regardless of the preference.
        XCTAssertFalse(
            CompactHUDContent.showsLiveTranscript(phase: .armed, showLiveTranscriptInHUD: true)
        )
        XCTAssertFalse(
            CompactHUDContent.showsLiveTranscript(phase: .success(message: "Done"), showLiveTranscriptInHUD: true)
        )
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
