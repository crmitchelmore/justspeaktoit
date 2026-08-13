import XCTest

@testable import SpeakCore

final class HandsFreeDictationTests: XCTestCase {
    // MARK: - Arming

    func testStartsDisarmedAndIgnoresVoiceActivity() {
        var machine = HandsFreeDictationMachine()

        XCTAssertEqual(machine.state, .disarmed)
        XCTAssertFalse(machine.isArmed)
        XCTAssertEqual(machine.handle(.speechDetected), [])
        XCTAssertEqual(machine.handle(.silenceElapsed), [])
        XCTAssertEqual(machine.state, .disarmed, "Nothing may capture while disarmed")
    }

    func testUserToggleArmsAndStartsTheDetector() {
        var machine = HandsFreeDictationMachine()

        XCTAssertEqual(machine.handle(.userToggled), [.startDetector])
        XCTAssertEqual(machine.state, .armedListening)
        XCTAssertTrue(machine.isArmed)
        XCTAssertFalse(machine.isCapturing)
    }

    func testArmingClearsThePreviousFailure() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.sessionFailed(.assetsUnavailable))
        XCTAssertEqual(machine.lastFailure, .assetsUnavailable)

        _ = machine.handle(.userToggled)

        XCTAssertNil(machine.lastFailure)
        XCTAssertEqual(machine.state, .armedListening)
    }

    // MARK: - The armed cycle

    func testSpeechStartsCaptureAndSilenceStopsIt() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)

        XCTAssertEqual(machine.handle(.speechDetected), [.startCapture])
        XCTAssertEqual(machine.state, .capturing)
        XCTAssertTrue(machine.isCapturing)

        XCTAssertEqual(machine.handle(.silenceElapsed), [.stopCapture, .startCooldown])
        XCTAssertEqual(machine.state, .coolingDown)
    }

    func testCooldownRearmsWithoutRestartingTheDetector() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.speechDetected)
        _ = machine.handle(.silenceElapsed)

        XCTAssertEqual(machine.handle(.cooldownElapsed), [])
        XCTAssertEqual(machine.state, .armedListening)
    }

    func testSpeechDuringCooldownDoesNotRetrigger() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.speechDetected)
        _ = machine.handle(.silenceElapsed)

        XCTAssertEqual(machine.handle(.speechDetected), [])
        XCTAssertEqual(machine.state, .coolingDown)
    }

    func testRepeatedSpeechWhileCapturingIsIgnored() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.speechDetected)

        XCTAssertEqual(machine.handle(.speechDetected), [])
        XCTAssertEqual(machine.state, .capturing)
    }

    func testCaptureFinishingOnItsOwnCoolsDownWithoutASecondStop() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.speechDetected)

        XCTAssertEqual(machine.handle(.captureFinished), [.startCooldown])
        XCTAssertEqual(machine.state, .coolingDown)
    }

    func testLateCaptureFinishedDuringCooldownIsIgnored() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.speechDetected)
        _ = machine.handle(.silenceElapsed)

        XCTAssertEqual(machine.handle(.captureFinished), [])
        XCTAssertEqual(machine.state, .coolingDown)
    }

    func testMultipleUtterancesReuseTheSameArmedSession() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)

        for _ in 0 ..< 3 {
            XCTAssertEqual(machine.handle(.speechDetected), [.startCapture])
            XCTAssertEqual(machine.handle(.silenceElapsed), [.stopCapture, .startCooldown])
            XCTAssertEqual(machine.handle(.cooldownElapsed), [])
        }

        XCTAssertEqual(machine.state, .armedListening)
        XCTAssertEqual(machine.handle(.userToggled), [.stopDetector])
    }

    // MARK: - Disarming

    func testDisarmingWhileListeningStopsTheDetector() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)

        XCTAssertEqual(machine.handle(.userToggled), [.stopDetector])
        XCTAssertEqual(machine.state, .disarmed)
    }

    func testDisarmingWhileCapturingStopsCaptureFirst() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.speechDetected)

        XCTAssertEqual(machine.handle(.userToggled), [.stopCapture, .stopDetector])
        XCTAssertEqual(machine.state, .disarmed)
    }

    func testDisarmingWhileCoolingDownStopsTheDetector() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.speechDetected)
        _ = machine.handle(.silenceElapsed)

        XCTAssertEqual(machine.handle(.userToggled), [.stopDetector])
        XCTAssertEqual(machine.state, .disarmed)
    }

    // MARK: - Failures

    func testFailureWhileListeningDisarmsAndReports() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)

        XCTAssertEqual(
            machine.handle(.sessionFailed(.detectorUnavailable)),
            [.stopDetector, .reportFailure(.detectorUnavailable)]
        )
        XCTAssertEqual(machine.state, .disarmed)
        XCTAssertEqual(machine.lastFailure, .detectorUnavailable)
    }

    func testFailureWhileCapturingStopsCaptureAndReports() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.speechDetected)

        XCTAssertEqual(
            machine.handle(.sessionFailed(.captureFailed)),
            [.stopCapture, .stopDetector, .reportFailure(.captureFailed)]
        )
        XCTAssertEqual(machine.state, .disarmed)
    }

    func testFailureWhileDisarmedStillReportsSoArmingNeverFailsSilently() {
        var machine = HandsFreeDictationMachine()

        XCTAssertEqual(
            machine.handle(.sessionFailed(.assetsUnavailable)),
            [.reportFailure(.assetsUnavailable)]
        )
        XCTAssertEqual(machine.state, .disarmed)
        XCTAssertEqual(machine.lastFailure, .assetsUnavailable)
    }

    func testEveryStateSurvivesEveryEvent() {
        let events: [HandsFreeDictationMachine.Event] = [
            .userToggled,
            .speechDetected,
            .silenceElapsed,
            .captureFinished,
            .cooldownElapsed,
            .sessionFailed(.captureFailed)
        ]
        let paths: [(HandsFreeDictationMachine.State, [HandsFreeDictationMachine.Event])] = [
            (.disarmed, []),
            (.armedListening, [.userToggled]),
            (.capturing, [.userToggled, .speechDetected]),
            (.coolingDown, [.userToggled, .speechDetected, .silenceElapsed])
        ]

        for (expectedState, setup) in paths {
            for event in events {
                var machine = HandsFreeDictationMachine()
                for step in setup { _ = machine.handle(step) }
                XCTAssertEqual(machine.state, expectedState)

                let effects = machine.handle(event)

                // Capture may only run from `capturing`, and only ever after a
                // `startCapture` effect — the core hands-free safety invariant.
                if machine.state == .capturing {
                    XCTAssertTrue(
                        effects.contains(.startCapture) || expectedState == .capturing,
                        "\(expectedState) + \(event) entered capture without starting it"
                    )
                }
                if effects.contains(.startCapture) {
                    XCTAssertEqual(machine.state, .capturing)
                }
            }
        }
    }

}

final class HandsFreeVoiceActivityTests: XCTestCase {
    // MARK: - Error classification

    func testFailureClassifiesModelErrors() {
        XCTAssertEqual(
            HandsFreeDictationMachine.Failure(AppleLocalModelError.speechDetectorUnavailable),
            .detectorUnavailable
        )
        XCTAssertEqual(
            HandsFreeDictationMachine.Failure(AppleLocalModelError.modelAssetsUnavailable),
            .assetsUnavailable
        )
        XCTAssertEqual(
            HandsFreeDictationMachine.Failure(AppleLocalModelError.localeUnsupported("en_GB")),
            .localeUnsupported
        )
        XCTAssertEqual(
            HandsFreeDictationMachine.Failure(AppleLocalModelError.compatibleAudioFormatUnavailable),
            .audioUnavailable
        )
        XCTAssertEqual(
            HandsFreeDictationMachine.Failure(URLError(.notConnectedToInternet)),
            .captureFailed
        )
    }

    func testEveryFailureHasAUserFacingMessage() {
        let failures: [HandsFreeDictationMachine.Failure] = [
            .detectorUnavailable, .assetsUnavailable, .localeUnsupported,
            .audioUnavailable, .captureFailed
        ]
        for failure in failures {
            XCTAssertFalse(failure.message.isEmpty, "\(failure) has no message")
        }
    }

    // MARK: - Voice activity debounce

    func testSpeechIsReportedOnTheLeadingEdgeOnly() {
        var tracker = HandsFreeVoiceActivityTracker()

        XCTAssertEqual(tracker.observe(speechDetected: true, atSeconds: 0.1), .speechDetected)
        XCTAssertNil(tracker.observe(speechDetected: true, atSeconds: 0.2))
        XCTAssertNil(tracker.observe(speechDetected: true, atSeconds: 1.0))
    }

    func testSilenceIsReportedOnlyAfterTheHoldWindow() {
        var tracker = HandsFreeVoiceActivityTracker()
        _ = tracker.observe(speechDetected: true, atSeconds: 0)

        XCTAssertNil(tracker.observe(speechDetected: false, atSeconds: 1.0))
        XCTAssertNil(tracker.observe(speechDetected: false, atSeconds: 1.5), "Breath-length pause")
        XCTAssertEqual(
            tracker.observe(
                speechDetected: false,
                atSeconds: 1.0 + HandsFreeDictationPolicy.silenceHoldSeconds
            ),
            .silenceElapsed
        )
    }

    func testSpeechResumingWithinTheHoldWindowCancelsTheStop() {
        var tracker = HandsFreeVoiceActivityTracker()
        _ = tracker.observe(speechDetected: true, atSeconds: 0)
        _ = tracker.observe(speechDetected: false, atSeconds: 1.0)

        XCTAssertEqual(tracker.observe(speechDetected: true, atSeconds: 1.4), .speechDetected)
        XCTAssertNil(tracker.observe(speechDetected: false, atSeconds: 2.0))
        XCTAssertNil(
            tracker.observe(speechDetected: false, atSeconds: 2.0 + 1.0),
            "The hold window restarts from the new silence"
        )
    }

    func testSilenceBeforeAnySpeechIsNotReported() {
        var tracker = HandsFreeVoiceActivityTracker()

        for step in 0 ..< 20 {
            XCTAssertNil(tracker.observe(speechDetected: false, atSeconds: Double(step)))
        }
    }

    func testSilenceIsReportedOncePerUtterance() {
        var tracker = HandsFreeVoiceActivityTracker()
        _ = tracker.observe(speechDetected: true, atSeconds: 0)
        _ = tracker.observe(speechDetected: false, atSeconds: 1.0)
        XCTAssertEqual(tracker.observe(speechDetected: false, atSeconds: 3.0), .silenceElapsed)

        XCTAssertNil(tracker.observe(speechDetected: false, atSeconds: 9.0))
        XCTAssertEqual(tracker.observe(speechDetected: true, atSeconds: 10.0), .speechDetected)
    }

    func testNonMonotonicTimestampsCannotStopCaptureEarly() {
        var tracker = HandsFreeVoiceActivityTracker()
        _ = tracker.observe(speechDetected: true, atSeconds: 5.0)
        _ = tracker.observe(speechDetected: false, atSeconds: 6.0)

        XCTAssertNil(tracker.observe(speechDetected: false, atSeconds: 0.0))
        XCTAssertNil(tracker.observe(speechDetected: false, atSeconds: 0.5))
        XCTAssertEqual(
            tracker.observe(speechDetected: false, atSeconds: 2.0),
            .silenceElapsed
        )
    }

    func testResetDropsThePartObservedUtterance() {
        var tracker = HandsFreeVoiceActivityTracker()
        _ = tracker.observe(speechDetected: true, atSeconds: 0)
        _ = tracker.observe(speechDetected: false, atSeconds: 1.0)

        tracker.reset()

        XCTAssertNil(tracker.observe(speechDetected: false, atSeconds: 10.0))
        XCTAssertEqual(tracker.observe(speechDetected: true, atSeconds: 11.0), .speechDetected)
    }

    func testTrackerFeedsTheMachineThroughAWholeUtterance() {
        var tracker = HandsFreeVoiceActivityTracker()
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)

        var effects: [HandsFreeDictationMachine.Effect] = []
        let samples: [(Bool, Double)] = [
            (false, 0.0), (true, 0.3), (true, 0.6), (true, 1.2),
            (false, 1.5), (false, 2.0), (false, 3.0)
        ]
        for (detected, seconds) in samples {
            guard let event = tracker.observe(speechDetected: detected, atSeconds: seconds) else {
                continue
            }
            effects.append(contentsOf: machine.handle(event))
        }

        XCTAssertEqual(effects, [.startCapture, .stopCapture, .startCooldown])
        XCTAssertEqual(machine.state, .coolingDown)
    }

    func testPolicyBudgetsAreOrderedForUsableHandsFreeDictation() {
        XCTAssertLessThan(
            HandsFreeDictationPolicy.speechStartBudgetSeconds,
            HandsFreeDictationPolicy.silenceHoldSeconds
        )
        XCTAssertLessThan(
            HandsFreeDictationPolicy.cooldownSeconds,
            HandsFreeDictationPolicy.silenceHoldSeconds
        )
        XCTAssertEqual(HandsFreeDictationPolicy.sensitivity, .medium)
    }
}
