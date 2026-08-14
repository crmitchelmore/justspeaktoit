import AVFoundation
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

    func testFailureInitialiser_ClassifiesModelErrors() {
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

    func testEveryFailure_HasAUserFacingMessage() {
        let failures: [HandsFreeDictationMachine.Failure] = [
            .detectorUnavailable, .assetsUnavailable, .localeUnsupported,
            .audioUnavailable, .captureFailed, .unsupportedConfiguration
        ]
        for failure in failures {
            XCTAssertFalse(failure.message.isEmpty, "\(failure) has no message")
        }
    }

    // MARK: - Voice activity debounce

    func testSpeechDetection_IsReportedOnTheLeadingEdgeOnly() {
        var tracker = HandsFreeVoiceActivityTracker()

        XCTAssertEqual(tracker.observe(speechDetected: true, atSeconds: 0.1), .speechDetected)
        XCTAssertNil(tracker.observe(speechDetected: true, atSeconds: 0.2))
        XCTAssertNil(tracker.observe(speechDetected: true, atSeconds: 1.0))
    }

    func testSilenceDetection_IsReportedOnlyAfterTheHoldWindow() {
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

    func testSpeechResumingWithinTheHoldWindow_CancelsTheStop() {
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

    func testSilenceBeforeAnySpeech_IsNotReported() {
        var tracker = HandsFreeVoiceActivityTracker()

        for step in 0 ..< 20 {
            XCTAssertNil(tracker.observe(speechDetected: false, atSeconds: Double(step)))
        }
    }

    func testSilenceDetection_IsReportedOncePerUtterance() {
        var tracker = HandsFreeVoiceActivityTracker()
        _ = tracker.observe(speechDetected: true, atSeconds: 0)
        _ = tracker.observe(speechDetected: false, atSeconds: 1.0)
        XCTAssertEqual(tracker.observe(speechDetected: false, atSeconds: 3.0), .silenceElapsed)

        XCTAssertNil(tracker.observe(speechDetected: false, atSeconds: 9.0))
        XCTAssertEqual(tracker.observe(speechDetected: true, atSeconds: 10.0), .speechDetected)
    }

    func testNonMonotonicTimestamps_CannotStopCaptureEarly() {
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

    func testReset_DropsThePartObservedUtterance() {
        var tracker = HandsFreeVoiceActivityTracker()
        _ = tracker.observe(speechDetected: true, atSeconds: 0)
        _ = tracker.observe(speechDetected: false, atSeconds: 1.0)

        tracker.reset()

        XCTAssertNil(tracker.observe(speechDetected: false, atSeconds: 10.0))
        XCTAssertEqual(tracker.observe(speechDetected: true, atSeconds: 11.0), .speechDetected)
    }

    func testTracker_FeedsTheMachineThroughAWholeUtterance() {
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

    func testPolicyBudgets_AreOrderedForUsableHandsFreeDictation() {
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


    func testPreRoll_KeepsOnlyTheConfiguredWindowAndDrainsOnce() throws {
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

    func testPreRoll_IgnoresEmptyAudioBuffers() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 1_000, channels: 1))
        let emptyBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        emptyBuffer.frameLength = 0
        let preRoll = HandsFreeAudioPreRollBuffer()

        preRoll.append(emptyBuffer)

        XCTAssertTrue(preRoll.takeSnapshot().isEmpty)
    }
}
