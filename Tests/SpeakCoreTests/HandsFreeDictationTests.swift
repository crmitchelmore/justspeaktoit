import XCTest

@testable import SpeakCore

final class HandsFreeDictationTests: XCTestCase {
    // MARK: - Arming

    func testInitialState_IsDisarmedAndIgnoresVoiceActivity() {
        var machine = HandsFreeDictationMachine()

        XCTAssertEqual(machine.state, .off)
        XCTAssertFalse(machine.isArmed)
        XCTAssertEqual(machine.handle(.speechDetected), [])
        XCTAssertEqual(machine.handle(.silenceElapsed), [])
        XCTAssertEqual(machine.state, .off, "Nothing may capture while disarmed")
    }

    func testUserToggle_ArmsAndStartsTheDetector() {
        var machine = HandsFreeDictationMachine()

        XCTAssertEqual(machine.handle(.userToggled), [.startDetector])
        XCTAssertEqual(machine.state, .arming)
        XCTAssertTrue(machine.isArmed)
        XCTAssertFalse(machine.isRecording)

        XCTAssertEqual(machine.handle(.detectorStarted), [])
        XCTAssertEqual(machine.state, .armed)
    }

    func testArming_ClearsThePreviousFailure() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.sessionFailed(.assetsUnavailable))
        XCTAssertEqual(machine.lastFailure, .assetsUnavailable)

        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)

        XCTAssertNil(machine.lastFailure)
        XCTAssertEqual(machine.state, .armed)
    }

    // MARK: - The armed cycle

    func testSpeechAndSilence_StartAndStopCapture() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)

        XCTAssertEqual(machine.handle(.speechDetected), [.startCapture])
        XCTAssertEqual(machine.state, .recording)
        XCTAssertTrue(machine.isRecording)

        XCTAssertEqual(machine.handle(.silenceElapsed), [.stopCapture])
        XCTAssertEqual(machine.state, .finalising)
    }

    func testCaptureFinished_RearmsWithoutRestartingTheDetector() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)
        _ = machine.handle(.silenceElapsed)

        XCTAssertEqual(machine.handle(.captureFinished), [])
        XCTAssertEqual(machine.state, .armed)
    }

    func testSpeechDuringFinalising_DoesNotRetrigger() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)
        _ = machine.handle(.silenceElapsed)

        XCTAssertEqual(machine.handle(.speechDetected), [])
        XCTAssertEqual(machine.state, .finalising)
    }

    func testRepeatedSpeechWhileCapturing_IsIgnored() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)

        XCTAssertEqual(machine.handle(.speechDetected), [])
        XCTAssertEqual(machine.state, .recording)
    }

    func testCaptureFinishedBeforeFinalising_IsIgnored() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)

        XCTAssertEqual(machine.handle(.captureFinished), [])
        XCTAssertEqual(machine.state, .recording)
    }

    func testLateCaptureFinishedAfterRearm_IsIgnored() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)
        _ = machine.handle(.silenceElapsed)

        XCTAssertEqual(machine.handle(.captureFinished), [])
        XCTAssertEqual(machine.state, .armed)
    }

    func testMultipleUtterances_ReuseTheSameArmedSession() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)

        for _ in 0 ..< 3 {
            XCTAssertEqual(machine.handle(.speechDetected), [.startCapture])
            XCTAssertEqual(machine.handle(.silenceElapsed), [.stopCapture])
            XCTAssertEqual(machine.handle(.captureFinished), [])
        }

        XCTAssertEqual(machine.state, .armed)
        XCTAssertEqual(machine.handle(.userToggled), [.stopDetector])
    }

    // MARK: - Disarming

    func testDisarmingWhileListening_StopsTheDetector() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)

        XCTAssertEqual(machine.handle(.userToggled), [.stopDetector])
        XCTAssertEqual(machine.state, .off)
    }

    func testDisarmingWhileArming_IgnoresLateDetectorStart() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userArmed)

        XCTAssertEqual(machine.handle(.userDisarmed), [.stopDetector])
        XCTAssertEqual(machine.handle(.detectorStarted), [])
        XCTAssertEqual(machine.state, .off)
    }

    func testDisarmingWhileCapturing_StopsCaptureFirst() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)

        XCTAssertEqual(machine.handle(.userToggled), [.cancelCapture, .stopDetector])
        XCTAssertEqual(machine.state, .off)
    }

    func testDisarmingWhileFinalising_StopsCaptureAndDetector() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)
        _ = machine.handle(.silenceElapsed)

        XCTAssertEqual(machine.handle(.userToggled), [.cancelCapture, .stopDetector])
        XCTAssertEqual(machine.state, .off)
    }

    // MARK: - Failures

    func testFailureWhileListening_DisarmsAndReports() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)

        XCTAssertEqual(
            machine.handle(.sessionFailed(.detectorUnavailable)),
            [.stopDetector, .reportFailure(.detectorUnavailable)]
        )
        XCTAssertEqual(machine.state, .off)
        XCTAssertEqual(machine.lastFailure, .detectorUnavailable)
    }

    func testFailureWhileCapturing_StopsCaptureAndReports() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)

        XCTAssertEqual(
            machine.handle(.sessionFailed(.captureFailed)),
            [.cancelCapture, .stopDetector, .reportFailure(.captureFailed)]
        )
        XCTAssertEqual(machine.state, .off)
    }

    // MARK: - Refused capture starts

    func testRejectedCaptureStart_DisarmsWithoutCancellingAnyCapture() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)

        let effects = machine.handle(.captureStartRejected(.captureFailed))

        XCTAssertEqual(effects, [.stopDetector, .reportFailure(.captureFailed)])
        XCTAssertFalse(
            effects.contains(.cancelCapture),
            "A refused start owns no capture, so it must never cancel one"
        )
        XCTAssertEqual(machine.state, .off)
        XCTAssertEqual(machine.lastFailure, .captureFailed)
    }

    func testRejectedCaptureStartWhileFinalising_StillLeavesTheCaptureAlone() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)
        _ = machine.handle(.silenceElapsed)

        XCTAssertEqual(
            machine.handle(.captureStartRejected(.unsupportedConfiguration)),
            [.stopDetector, .reportFailure(.unsupportedConfiguration)]
        )
        XCTAssertEqual(machine.state, .off)
    }

    func testRejectedCaptureStartAfterDisarm_IsIgnored() {
        var machine = HandsFreeDictationMachine()

        XCTAssertEqual(machine.handle(.captureStartRejected(.captureFailed)), [])
        XCTAssertEqual(machine.state, .off)
        XCTAssertNil(machine.lastFailure)
    }

    func testLateFailureAfterDisarm_IsIgnored() {
        var machine = HandsFreeDictationMachine()

        XCTAssertEqual(
            machine.handle(.sessionFailed(.assetsUnavailable)),
            []
        )
        XCTAssertEqual(machine.state, .off)
        XCTAssertNil(machine.lastFailure)
    }

    func testEveryState_HandlesEveryEvent() {
        let events: [HandsFreeDictationMachine.Event] = [
            .userToggled,
            .userArmed,
            .userDisarmed,
            .detectorStarted,
            .speechDetected,
            .silenceElapsed,
            .captureFinished,
            .captureStartRejected(.captureFailed),
            .sessionFailed(.captureFailed)
        ]
        let paths: [(HandsFreeDictationMachine.State, [HandsFreeDictationMachine.Event])] = [
            (.off, []),
            (.arming, [.userArmed]),
            (.armed, [.userArmed, .detectorStarted]),
            (.recording, [.userArmed, .detectorStarted, .speechDetected]),
            (.finalising, [.userArmed, .detectorStarted, .speechDetected, .silenceElapsed])
        ]

        for (expectedState, setup) in paths {
            for event in events {
                var machine = HandsFreeDictationMachine()
                for step in setup { _ = machine.handle(step) }
                XCTAssertEqual(machine.state, expectedState)

                let effects = machine.handle(event)

                // Capture may only run from `recording`, and only ever after a
                // `startCapture` effect — the core hands-free safety invariant.
                if machine.state == .recording {
                    XCTAssertTrue(
                        effects.contains(.startCapture) || expectedState == .recording,
                        "\(expectedState) + \(event) entered capture without starting it"
                    )
                }
                if effects.contains(.startCapture) {
                    XCTAssertEqual(machine.state, .recording)
                }
                // A refused start never cancels a capture, from any state: the
                // recording that refused it belongs to somebody else.
                if case .captureStartRejected = event {
                    XCTAssertFalse(
                        effects.contains(.cancelCapture),
                        "\(expectedState) + \(event) cancelled a capture it does not own"
                    )
                }
            }
        }
    }

}
