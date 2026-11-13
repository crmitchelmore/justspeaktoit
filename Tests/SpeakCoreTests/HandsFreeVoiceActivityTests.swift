import AVFoundation
import XCTest

@testable import SpeakCore

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
            .audioFormatUnavailable,
            "An empty SpeechAnalyzer format is not a microphone failure (#1553)"
        )
        XCTAssertEqual(
            HandsFreeDictationMachine.Failure(URLError(.notConnectedToInternet)),
            .captureFailed
        )
    }

    func testEveryFailure_HasAUserFacingMessage() {
        let failures: [HandsFreeDictationMachine.Failure] = [
            .detectorUnavailable, .assetsUnavailable, .localeUnsupported,
            .audioUnavailable, .audioFormatUnavailable, .captureFailed, .unsupportedConfiguration
        ]
        for failure in failures {
            XCTAssertFalse(failure.message.isEmpty, "\(failure) has no message")
        }
        XCTAssertEqual(Set(failures.map(\.message)).count, failures.count, "Every failure reads differently")
        XCTAssertFalse(HandsFreeDictationMachine.Failure.audioFormatUnavailable.message.contains("microphone"))
    }

    // MARK: - Microphone voice-activity session

    func testVoiceActivitySession_ReportsSpeechFromMicrophoneBuffersButNotSilence() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true)
        )
        let reports = LockedReports()
        let session = HandsFreeVoiceActivitySession { reports.append($0) }
        func send(seconds: Double, amplitude: Double) throws {
            for _ in 0 ..< Int(seconds * 10) {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
                buffer.frameLength = 4_800
                let samples = try XCTUnwrap(buffer.int16ChannelData)[0]
                for frame in 0 ..< 4_800 {
                    let value = Int16(amplitude * 32_767 * sin(Double(frame) * 2 * .pi * 200 / 48_000))
                    samples[frame * 2] = value
                    samples[frame * 2 + 1] = value
                }
                session.send(buffer)
            }
        }

        try send(seconds: 2, amplitude: 0)
        XCTAssertFalse(reports.values.contains { $0.speechDetected })
        try send(seconds: 0.5, amplitude: 0.2)
        XCTAssertTrue(reports.values.last?.speechDetected ?? false)

        session.cancel()
        let count = reports.values.count
        try send(seconds: 0.5, amplitude: 0.2)
        XCTAssertEqual(reports.values.count, count, "A cancelled session reports nothing")
    }

    func testVoiceActivitySession_IgnoresAnEmptyFormatBuffer() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 0
        XCTAssertNil(HandsFreeVoiceActivitySession.monoSamples(from: buffer))
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

private final class LockedReports: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AppleSpeechActivityUpdate] = []

    func append(_ update: AppleSpeechActivityUpdate) {
        lock.lock()
        stored.append(update)
        lock.unlock()
    }

    var values: [AppleSpeechActivityUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
