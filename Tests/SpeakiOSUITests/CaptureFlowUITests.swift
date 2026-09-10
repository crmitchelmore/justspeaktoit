import XCTest

/// End-to-end cover for the in-app capture journey on the Simulator (issue #998).
///
/// These drive the real `ContentView` button through the real
/// `TranscriberCoordinator`, with the deterministic
/// `JUSTSPEAKTOIT_SIMULATOR_TRANSCRIPT` hook standing in for the microphone
/// and the transcriber
/// (`Sources/SpeakiOS/Views/ContentView.swift`, the `#if DEBUG &&
/// targetEnvironment(simulator)` branch in `TranscriberCoordinator.start()`).
/// Everything either side of that branch — the button's state machine, the
/// text that reaches the screen, and which affordances the user is offered
/// while recording versus after stopping — is production code.
///
/// **Simulator, not device.** The hook returns before any audio session is
/// configured, so nothing here proves AVAudioSession behaviour, and ActivityKit
/// renders in system UI that XCUITest cannot see, so nothing here proves Live
/// Activity content either. Those two live on the manual device matrix
/// (`.github/ISSUE_TEMPLATE/action_button_device_matrix.md`) and, for the
/// activity status order, in `Tests/SpeakiOSTests`. What this class asserts is
/// the user-visible status order the *app* owns: idle → recording → idle, with
/// the transcript on screen and copy offered exactly once the session is over.
///
/// Determinism is the whole point — the existing UI class in this bundle is
/// flaky (issue #793), so every wait here is on a specific element, there are
/// no sleeps, no retries, and no assertion that depends on a timer.
final class CaptureFlowUITests: XCTestCase {

    /// A phrase no other label in the app contains, so `staticTexts` matching
    /// is unambiguous.
    private static let transcript = "Regression harness transcript zulu"

    /// Cold simulators on loaded CI runners are slow to first frame; a generous
    /// wait costs nothing when the element does turn up (issue #793).
    private static let launchTimeout: TimeInterval = 60
    private static let elementTimeout: TimeInterval = 15

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        // The app reads this in `SharedTranscriptionState`; setting it in the
        // launch environment is what makes the capture path deterministic.
        app.launchEnvironment["JUSTSPEAKTOIT_SIMULATOR_TRANSCRIPT"] = Self.transcript
        app.launch()

        XCTAssertTrue(
            recordToggle.waitForExistence(timeout: Self.launchTimeout),
            "The record button did not appear within \(Int(Self.launchTimeout))s of launch"
        )
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - The in-app button

    /// The status order the user actually sees, and the rule that copy is
    /// offered only once the session has finished.
    func testInAppButton_runsIdleToRecordingToIdleAndOffersCopyOnlyAfterStopping() {
        XCTAssertEqual(recordToggle.label, "Start recording", "The app did not launch idle")
        XCTAssertFalse(
            copyButton.exists,
            "Copy must not be offered before there is any transcript"
        )

        recordToggle.tap()

        XCTAssertTrue(
            waitForRecordToggleLabel("Stop recording"),
            "The button did not move to the recording state after a tap"
        )
        XCTAssertTrue(
            transcriptText.waitForExistence(timeout: Self.elementTimeout),
            "The transcript did not reach the screen while recording"
        )
        // Copy and Polish are deliberately withheld mid-session; a user who
        // taps copy while the transcript is still growing gets a partial.
        XCTAssertFalse(copyButton.exists, "Copy must not be offered while recording")
        XCTAssertFalse(polishButton.exists, "Polish must not be offered while recording")

        recordToggle.tap()

        XCTAssertTrue(
            waitForRecordToggleLabel("Start recording"),
            "The button did not return to idle after the session was stopped"
        )
        XCTAssertTrue(
            copyButton.waitForExistence(timeout: Self.elementTimeout),
            "Copy was not offered once the session had finished"
        )
        XCTAssertTrue(
            transcriptText.exists,
            "Stopping must not clear the transcript the user just dictated"
        )
    }

    /// Copying a finished transcript must leave the screen usable: the
    /// transcript stays, and copy stays available for a second attempt.
    ///
    /// The "Copied to clipboard" confirmation itself is deliberately **not**
    /// asserted. It reverts on a two-second timer, which is shorter than one
    /// XCUITest query round-trip on a loaded runner — an assertion on it failed
    /// once in three local runs. A test that flakes one time in three is worse
    /// than no test (issue #793), and there is no durable trace of the copy to
    /// assert instead: the app writes `UIPasteboard.general` and keeps no
    /// record of having done so.
    func testInAppButton_copyingAFinishedTranscriptLeavesItOnScreenAndRecopyable() {
        captureOnce()

        let copy = copyButton
        XCTAssertTrue(
            copy.waitForExistence(timeout: Self.elementTimeout),
            "Copy was not offered after a finished capture"
        )
        copy.tap()

        XCTAssertTrue(
            transcriptText.exists,
            "Copying must not clear the transcript it just copied"
        )
        XCTAssertTrue(
            copyButton.waitForExistence(timeout: Self.elementTimeout),
            "Copy must stay available so a user who missed the confirmation can retry"
        )
    }

    /// A second capture replaces the previous transcript rather than appending
    /// to it: `toggleRecording()` clears `displayText` before starting, and the
    /// coordinator resets `partialText`. If either regressed, the screen would
    /// show the phrase twice.
    func testSecondCapture_replacesThePreviousTranscriptInsteadOfAppending() {
        captureOnce()
        XCTAssertTrue(transcriptText.waitForExistence(timeout: Self.elementTimeout))

        captureOnce()

        XCTAssertTrue(
            transcriptText.waitForExistence(timeout: Self.elementTimeout),
            "The second capture did not put its transcript on screen"
        )
        XCTAssertFalse(
            app.staticTexts["\(Self.transcript) \(Self.transcript)"].exists,
            "The second capture appended to the first instead of replacing it"
        )
        XCTAssertEqual(
            app.staticTexts.matching(
                NSPredicate(format: "label == %@", Self.transcript)
            ).count,
            1,
            "Exactly one transcript view should be showing after a second capture"
        )
    }

    // MARK: - Helpers

    private var recordToggle: XCUIElement {
        app.buttons["recordToggleButton"]
    }

    private var copyButton: XCUIElement {
        app.buttons["copyTranscriptButton"]
    }

    private var polishButton: XCUIElement {
        app.buttons["polishTranscriptButton"]
    }

    private var transcriptText: XCUIElement {
        app.staticTexts[Self.transcript]
    }

    /// Runs one full start/stop cycle and returns once the button is idle again.
    private func captureOnce() {
        recordToggle.tap()
        XCTAssertTrue(
            waitForRecordToggleLabel("Stop recording"),
            "The session did not start"
        )
        recordToggle.tap()
        XCTAssertTrue(
            waitForRecordToggleLabel("Start recording"),
            "The session did not finish"
        )
    }

    /// Waits on the button's accessibility label rather than polling state, so
    /// there is no sleep anywhere in this class.
    private func waitForRecordToggleLabel(_ label: String) -> Bool {
        let matched = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: recordToggle
        )
        return XCTWaiter().wait(for: [matched], timeout: Self.elementTimeout) == .completed
    }
}
