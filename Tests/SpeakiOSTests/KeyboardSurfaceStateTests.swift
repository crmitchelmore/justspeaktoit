#if IOS_KEYBOARD_FEATURE
import SpeakCore
import XCTest

final class KeyboardSurfaceStateTests: XCTestCase {
    private func surface(
        _ phase: KeyboardSurfaceState.Phase, liveText: String = "", isBusy: Bool = false, bothChips: Bool = false
    ) -> KeyboardSurfaceState {
        KeyboardSurfaceState(phase: phase, liveText: liveText, isBusy: isBusy, showsBothChips: bothChips)
    }

    func testLiveText_replacesTheStatusLineAndIsReadWithItsStatus() {
        let stopping = surface(.direct(.stopping), liveText: "hello there")
        XCTAssertEqual(stopping.stripText, "hello there")
        XCTAssertEqual(stopping.stripAccessibilityLabel, "Finishing dictation. hello there")

        let idle = surface(.direct(.idle))
        XCTAssertEqual(idle.stripText, "Tap the mic and speak. Words appear as you talk.")
        XCTAssertEqual(idle.stripAccessibilityLabel, idle.stripText)
    }

    func testWaitingForApp_asksForTheConnectTapAndNamesTheRecordedEndReason() {
        XCTAssertEqual(
            surface(.handoff(.waitingForApp, endReason: nil)).stripText,
            "Tap the mic to connect Just Speak. It opens briefly; come back here and start speaking."
        )
        XCTAssertEqual(
            surface(.handoff(.waitingForApp, endReason: .sessionWindowElapsed)).stripText,
            "Instant Dictation ended after four hours. Tap the mic to reconnect Just Speak."
        )
        XCTAssertEqual(
            surface(.handoff(.openAppManually, endReason: nil)).stripText,
            "Open Just Speak once to reconnect Instant Dictation, then return here."
        )
    }

    func testWaitingForApp_makesTheMicAConnectKey() {
        let waiting = surface(.handoff(.waitingForApp, endReason: nil))
        XCTAssertFalse(waiting.micDisabled)
        XCTAssertEqual(waiting.micCaption, "Connect")
        XCTAssertEqual(waiting.micAccessibilityLabel, "Connect Just Speak")
        XCTAssertNil(surface(.handoff(.waitingForApp, endReason: nil), bothChips: true).micCaption)

        let manual = surface(.handoff(.openAppManually, endReason: nil))
        XCTAssertTrue(manual.micDisabled)
        XCTAssertEqual(manual.micAccessibilityLabel, "Start dictation")
    }

    func testStripSymbolAndTone_followThePhase() {
        XCTAssertEqual(surface(.direct(.recording)).stripTone, .live)
        XCTAssertEqual(surface(.direct(.failed(.noSpeech))).stripTone, .warning)
        XCTAssertEqual(surface(.handoff(.inserted, endReason: nil)).stripTone, .success)
        XCTAssertEqual(surface(.handoff(.waitingForApp, endReason: nil)).stripSymbol, "arrow.up.forward.app")
        XCTAssertEqual(surface(.handoff(.waitingForApp, endReason: nil)).stripTone, .neutral)
        XCTAssertEqual(surface(.blocked(.fullAccessRequired)).stripTone, .warning)
    }

    func testMicCaption_dropsWithBothChipsAndWhenBlocked() {
        XCTAssertEqual(surface(.direct(.idle)).micCaption, "Speak")
        XCTAssertEqual(surface(.handoff(.recording, endReason: nil)).micCaption, "Stop")
        XCTAssertNil(surface(.handoff(.recording, endReason: nil), bothChips: true).micCaption)
        XCTAssertNil(surface(.blocked(.sharedContainerUnavailable)).micCaption)
    }

    func testMicAndEditingKeys_lockOnlyWhileTheirPathIsBusy() {
        let blocked = surface(.blocked(.fullAccessRequired), isBusy: true)
        XCTAssertTrue(blocked.micDisabled)
        XCTAssertFalse(blocked.controlsDisabled)

        XCTAssertTrue(surface(.direct(.recording), isBusy: true).controlsDisabled)
        XCTAssertFalse(surface(.direct(.recording), isBusy: true).micDisabled, "the mic is the stop key")
        XCTAssertTrue(surface(.direct(.stopping)).micDisabled)

        XCTAssertTrue(surface(.handoff(.transcribing, endReason: nil)).controlsDisabled)
        XCTAssertFalse(surface(.handoff(.waitingForApp, endReason: nil)).controlsDisabled)
    }

    func testCancel_isOfferedOnlyWhileACaptureCanStillBeAbandoned() {
        XCTAssertTrue(surface(.direct(.starting)).showsCancel)
        XCTAssertFalse(surface(.direct(.stopping)).showsCancel)
        XCTAssertTrue(surface(.handoff(.transcribing, endReason: nil)).showsCancel)
        XCTAssertFalse(surface(.handoff(.inserted, endReason: nil)).showsCancel)
        XCTAssertFalse(surface(.blocked(.fullAccessRequired)).showsCancel)
    }
}
#endif
