import XCTest

@testable import SpeakCore

final class KeyboardDictationMachineTests: XCTestCase {
    // MARK: - Capture path planning

    func testPlannerBlocksWithoutFullAccessRegardlessOfPermissions() {
        let path = KeyboardCapturePlanner.path(
            hasFullAccess: false,
            sharedContainerAvailable: true,
            microphonePermission: .granted,
            speechRecognitionPermission: .granted,
            speechRecognizerAvailable: true
        )

        XCTAssertEqual(path, .blocked(.fullAccessRequired))
    }

    func testPlannerBlocksWhenSharedContainerIsMissing() {
        let path = KeyboardCapturePlanner.path(
            hasFullAccess: true,
            sharedContainerAvailable: false,
            microphonePermission: .granted,
            speechRecognitionPermission: .granted,
            speechRecognizerAvailable: true
        )

        XCTAssertEqual(path, .blocked(.sharedContainerUnavailable))
    }

    func testPlannerPrefersDirectCaptureEvenBeforePermissionPrompts() {
        let path = KeyboardCapturePlanner.path(
            hasFullAccess: true,
            sharedContainerAvailable: true,
            microphonePermission: .undetermined,
            speechRecognitionPermission: .undetermined,
            speechRecognizerAvailable: true
        )

        XCTAssertEqual(path, .direct)
    }

    func testPlannerFallsBackToHandoffWhenDirectCaptureIsDenied() {
        let deniedMic = KeyboardCapturePlanner.path(
            hasFullAccess: true,
            sharedContainerAvailable: true,
            microphonePermission: .denied,
            speechRecognitionPermission: .granted,
            speechRecognizerAvailable: true
        )
        let deniedSpeech = KeyboardCapturePlanner.path(
            hasFullAccess: true,
            sharedContainerAvailable: true,
            microphonePermission: .granted,
            speechRecognitionPermission: .denied,
            speechRecognizerAvailable: true
        )
        let noRecognizer = KeyboardCapturePlanner.path(
            hasFullAccess: true,
            sharedContainerAvailable: true,
            microphonePermission: .granted,
            speechRecognitionPermission: .granted,
            speechRecognizerAvailable: false
        )

        XCTAssertEqual(deniedMic, .handoff)
        XCTAssertEqual(deniedSpeech, .handoff)
        XCTAssertEqual(noRecognizer, .handoff)
    }

    func testPlannerWithDirectCaptureDisabled_selectsHandoffBeforePermissions() {
        let path = KeyboardCapturePlanner.path(
            hasFullAccess: true,
            sharedContainerAvailable: true,
            directCapturePolicy: .disabled,
            microphonePermission: .undetermined,
            speechRecognitionPermission: .undetermined,
            speechRecognizerAvailable: true
        )

        XCTAssertEqual(path, .handoff)
    }

    // MARK: - Happy path

    func testMicTapRecordsStreamsAndFinishes() {
        var machine = KeyboardDictationMachine()

        XCTAssertEqual(machine.handle(.micTapped), [.startCapture])
        XCTAssertEqual(machine.state, .starting)

        XCTAssertEqual(machine.handle(.captureStarted), [])
        XCTAssertEqual(machine.state, .recording)

        let effects = machine.handle(.hypothesis("hello there"))
        XCTAssertEqual(
            effects,
            [.applyEdit(KeyboardTranscriptEdit(deleteCount: 0, insertion: "hello there"))]
        )
        XCTAssertEqual(machine.liveText, "hello there")

        XCTAssertEqual(machine.handle(.stopTapped), [.stopCapture])
        XCTAssertEqual(machine.state, .stopping)

        let final = machine.handle(.finalized("hello there."))
        XCTAssertEqual(
            final,
            [.applyEdit(KeyboardTranscriptEdit(deleteCount: 0, insertion: "."))]
        )
        XCTAssertEqual(machine.state, .finished)
        XCTAssertEqual(machine.liveText, "hello there.")
    }

    func testMicTapTogglesStopWhileRecording() {
        var machine = KeyboardDictationMachine()
        _ = machine.handle(.micTapped)
        _ = machine.handle(.captureStarted)

        XCTAssertEqual(machine.handle(.micTapped), [.stopCapture])
        XCTAssertEqual(machine.state, .stopping)
    }

    func testHypothesesStillApplyWhileStopping() {
        var machine = KeyboardDictationMachine()
        _ = machine.handle(.micTapped)
        _ = machine.handle(.captureStarted)
        _ = machine.handle(.hypothesis("first"))
        _ = machine.handle(.stopTapped)

        let effects = machine.handle(.hypothesis("first words"))
        XCTAssertEqual(
            effects,
            [.applyEdit(KeyboardTranscriptEdit(deleteCount: 0, insertion: " words"))]
        )
    }

    func testRestartAfterFinishBeginsFreshSession() {
        var machine = KeyboardDictationMachine()
        _ = machine.handle(.micTapped)
        _ = machine.handle(.captureStarted)
        _ = machine.handle(.hypothesis("first run"))
        _ = machine.handle(.finalized("first run"))
        XCTAssertEqual(machine.state, .finished)

        XCTAssertEqual(machine.handle(.micTapped), [.startCapture])
        _ = machine.handle(.captureStarted)
        // The new session must not delete the previous session's text.
        let effects = machine.handle(.hypothesis("second"))
        XCTAssertEqual(
            effects,
            [.applyEdit(KeyboardTranscriptEdit(deleteCount: 0, insertion: "second"))]
        )
    }

    // MARK: - Failures and early ends

    func testTapWhileStartingAborts() {
        var machine = KeyboardDictationMachine()
        _ = machine.handle(.micTapped)

        XCTAssertEqual(machine.handle(.micTapped), [.cancelCapture])
        XCTAssertEqual(machine.state, .idle)
    }

    func testCaptureFailureSurfacesAndCancels() {
        var machine = KeyboardDictationMachine()
        _ = machine.handle(.micTapped)

        XCTAssertEqual(
            machine.handle(.captureFailed(.microphoneUnavailable)),
            [.cancelCapture]
        )
        XCTAssertEqual(machine.state, .failed(.microphoneUnavailable))
    }

    func testEmptyFinalTranscriptReportsNoSpeech() {
        var machine = KeyboardDictationMachine()
        _ = machine.handle(.micTapped)
        _ = machine.handle(.captureStarted)
        _ = machine.handle(.stopTapped)

        XCTAssertEqual(machine.handle(.finalized("  ")), [])
        XCTAssertEqual(machine.state, .failed(.noSpeech))
    }

    func testInterruptionWithInsertedTextFinishesInsteadOfFailing() {
        var machine = KeyboardDictationMachine()
        _ = machine.handle(.micTapped)
        _ = machine.handle(.captureStarted)
        _ = machine.handle(.hypothesis("keep these words"))

        XCTAssertEqual(machine.handle(.interrupted), [.cancelCapture])
        XCTAssertEqual(machine.state, .finished)
        XCTAssertEqual(machine.liveText, "keep these words")
    }

    func testInterruptionWithoutTextFails() {
        var machine = KeyboardDictationMachine()
        _ = machine.handle(.micTapped)
        _ = machine.handle(.captureStarted)

        XCTAssertEqual(machine.handle(.interrupted), [.cancelCapture])
        XCTAssertEqual(machine.state, .failed(.audioInterrupted))
    }

    func testTargetChangeStopsStreamingIntoNewField() {
        var machine = KeyboardDictationMachine()
        _ = machine.handle(.micTapped)
        _ = machine.handle(.captureStarted)
        _ = machine.handle(.hypothesis("typed into old field"))

        XCTAssertEqual(machine.handle(.targetChanged), [.cancelCapture])
        XCTAssertEqual(machine.state, .finished)
        // No further hypotheses may produce edits for the new field.
        XCTAssertEqual(machine.handle(.hypothesis("more words")), [])
    }

    func testDismissalCancelsAndResets() {
        var machine = KeyboardDictationMachine()
        _ = machine.handle(.micTapped)
        _ = machine.handle(.captureStarted)
        _ = machine.handle(.hypothesis("halfway"))

        XCTAssertEqual(machine.handle(.dismissed), [.cancelCapture])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.liveText, "")
    }

    func testDismissalWhenIdleHasNoEffects() {
        var machine = KeyboardDictationMachine()

        XCTAssertEqual(machine.handle(.dismissed), [])
        XCTAssertEqual(machine.state, .idle)
    }

    func testEventsOutsideActiveSessionAreIgnored() {
        var machine = KeyboardDictationMachine()

        XCTAssertEqual(machine.handle(.hypothesis("ghost")), [])
        XCTAssertEqual(machine.handle(.finalized("ghost")), [])
        XCTAssertEqual(machine.handle(.stopTapped), [])
        XCTAssertEqual(machine.handle(.captureStarted), [])
        XCTAssertEqual(machine.state, .idle)
    }
}
