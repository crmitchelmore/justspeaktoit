import AVFoundation
import XCTest

@testable import SpeakCore

final class HandsFreeDictationTests: XCTestCase {
    // MARK: - Arming

    func testStartsDisarmedAndIgnoresVoiceActivity() {
        var machine = HandsFreeDictationMachine()

        XCTAssertEqual(machine.state, .off)
        XCTAssertFalse(machine.isArmed)
        XCTAssertEqual(machine.handle(.speechDetected), [])
        XCTAssertEqual(machine.handle(.silenceElapsed), [])
        XCTAssertEqual(machine.state, .off, "Nothing may capture while disarmed")
    }

    func testUserToggleArmsAndStartsTheDetector() {
        var machine = HandsFreeDictationMachine()

        XCTAssertEqual(machine.handle(.userToggled), [.startDetector])
        XCTAssertEqual(machine.state, .arming)
        XCTAssertTrue(machine.isArmed)
        XCTAssertFalse(machine.isRecording)

        XCTAssertEqual(machine.handle(.detectorStarted), [])
        XCTAssertEqual(machine.state, .armed)
    }

    func testArmingClearsThePreviousFailure() {
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

    func testSpeechStartsCaptureAndSilenceStopsIt() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)

        XCTAssertEqual(machine.handle(.speechDetected), [.startCapture])
        XCTAssertEqual(machine.state, .recording)
        XCTAssertTrue(machine.isRecording)

        XCTAssertEqual(machine.handle(.silenceElapsed), [.stopCapture])
        XCTAssertEqual(machine.state, .finalising)
    }

    func testCooldownRearmsWithoutRestartingTheDetector() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)
        _ = machine.handle(.silenceElapsed)

        XCTAssertEqual(machine.handle(.captureFinished), [])
        XCTAssertEqual(machine.state, .armed)
    }

    func testSpeechDuringCooldownDoesNotRetrigger() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)
        _ = machine.handle(.silenceElapsed)

        XCTAssertEqual(machine.handle(.speechDetected), [])
        XCTAssertEqual(machine.state, .finalising)
    }

    func testRepeatedSpeechWhileCapturingIsIgnored() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)

        XCTAssertEqual(machine.handle(.speechDetected), [])
        XCTAssertEqual(machine.state, .recording)
    }

    func testCaptureCannotFinishBeforeFinalisingStarts() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)

        XCTAssertEqual(machine.handle(.captureFinished), [])
        XCTAssertEqual(machine.state, .recording)
    }

    func testLateCaptureFinishedDuringCooldownIsIgnored() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)
        _ = machine.handle(.silenceElapsed)

        XCTAssertEqual(machine.handle(.captureFinished), [])
        XCTAssertEqual(machine.state, .armed)
    }

    func testMultipleUtterancesReuseTheSameArmedSession() {
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

    func testDisarmingWhileListeningStopsTheDetector() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)

        XCTAssertEqual(machine.handle(.userToggled), [.stopDetector])
        XCTAssertEqual(machine.state, .off)
    }

    func testDisarmingWhileArmingMakesLateDetectorStartAuthoritativelyIgnored() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userArmed)

        XCTAssertEqual(machine.handle(.userDisarmed), [.stopDetector])
        XCTAssertEqual(machine.handle(.detectorStarted), [])
        XCTAssertEqual(machine.state, .off)
    }

    func testDisarmingWhileCapturingStopsCaptureFirst() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)

        XCTAssertEqual(machine.handle(.userToggled), [.cancelCapture, .stopDetector])
        XCTAssertEqual(machine.state, .off)
    }

    func testDisarmingWhileCoolingDownStopsTheDetector() {
        var machine = HandsFreeDictationMachine()
        _ = machine.handle(.userToggled)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)
        _ = machine.handle(.silenceElapsed)

        XCTAssertEqual(machine.handle(.userToggled), [.cancelCapture, .stopDetector])
        XCTAssertEqual(machine.state, .off)
    }

    // MARK: - Failures

    func testFailureWhileListeningDisarmsAndReports() {
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

    func testFailureWhileCapturingStopsCaptureAndReports() {
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

    func testLateFailureAfterDisarmIsIgnored() {
        var machine = HandsFreeDictationMachine()

        XCTAssertEqual(
            machine.handle(.sessionFailed(.assetsUnavailable)),
            []
        )
        XCTAssertEqual(machine.state, .off)
        XCTAssertNil(machine.lastFailure)
    }

    func testEveryStateSurvivesEveryEvent() {
        let events: [HandsFreeDictationMachine.Event] = [
            .userToggled,
            .userArmed,
            .userDisarmed,
            .detectorStarted,
            .speechDetected,
            .silenceElapsed,
            .captureFinished,
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
            .audioUnavailable, .captureFailed, .unsupportedConfiguration
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
                atSeconds: 1.0 + HandsFreeDictationPolicy.defaultSilenceHoldSeconds
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
        _ = machine.handle(.detectorStarted)

        var effects: [HandsFreeDictationMachine.Effect] = []
        let samples: [(Bool, Double)] = [
            (false, 0.0), (true, 0.3), (true, 0.6), (true, 1.2),
            (false, 1.5), (false, 2.0), (false, 3.6)
        ]
        for (detected, seconds) in samples {
            guard let event = tracker.observe(speechDetected: detected, atSeconds: seconds) else {
                continue
            }
            effects.append(contentsOf: machine.handle(event))
        }

        XCTAssertEqual(effects, [.startCapture, .stopCapture])
        XCTAssertEqual(machine.state, .finalising)
    }

    func testPolicyBudgetsAreOrderedForUsableHandsFreeDictation() {
        XCTAssertLessThan(
            HandsFreeDictationPolicy.speechStartBudgetSeconds,
            HandsFreeDictationPolicy.defaultSilenceHoldSeconds
        )
        XCTAssertLessThan(
            HandsFreeDictationPolicy.preRollSeconds,
            HandsFreeDictationPolicy.defaultSilenceHoldSeconds
        )
        XCTAssertEqual(HandsFreeDictationPolicy.sensitivity, .medium)
        XCTAssertEqual(HandsFreeDictationPolicy.silenceHoldSeconds(configured: 0.1), 0.5)
        XCTAssertEqual(HandsFreeDictationPolicy.silenceHoldSeconds(configured: 9), 5)
    }


    func testPreRollKeepsOnlyTheConfiguredWindowAndDrainsOnce() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 1_000, channels: 1))
        let preRoll = HandsFreeAudioPreRollBuffer(duration: 0.5)
        for _ in 0 ..< 4 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 200))
            buffer.frameLength = 200
            preRoll.append(buffer)
        }

        let snapshot = preRoll.takeSnapshot()

        XCTAssertEqual(snapshot.reduce(0) { $0 + Int($1.frameLength) }, 400)
        XCTAssertTrue(preRoll.takeSnapshot().isEmpty)
    }
}
