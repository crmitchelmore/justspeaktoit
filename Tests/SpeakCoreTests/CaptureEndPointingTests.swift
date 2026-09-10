import XCTest
@testable import SpeakCore

/// Drives `CaptureEndPointingMonitor` with synthetic level sequences.
///
/// The two failure modes this unit exists to prevent are the ones under test:
/// stopping while the user is still talking (truncation), and never stopping at
/// all (a hot microphone). Everything else is detail.
final class CaptureEndPointingTests: XCTestCase {
    private let step = CaptureEndPointingPolicy.sampleIntervalSeconds

    /// Feeds `seconds` worth of samples at the poll interval and returns every
    /// decision that was not `.waiting`, tagged with the time it happened.
    private func run(
        _ monitor: inout CaptureEndPointingMonitor,
        from start: Double,
        seconds: Double,
        speech: Bool
    ) -> [(time: Double, decision: CaptureEndPointingDecision)] {
        var events: [(time: Double, decision: CaptureEndPointingDecision)] = []
        var time = start
        let end = start + seconds
        while time < end {
            let decision = monitor.observe(speechDetected: speech, atSeconds: time)
            if decision != .waiting { events.append((time, decision)) }
            time += step
        }
        return events
    }

    // MARK: - Truncation

    func testSilenceBeforeAnySpeechNeverStops() {
        // Someone presses the Action Button, then takes half a minute to
        // gather their thoughts. Nothing may end that capture.
        var monitor = CaptureEndPointingMonitor(silenceWindow: 3, maximumDuration: 600)
        let events = run(&monitor, from: 0, seconds: 30, speech: false)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(monitor.hasStopped)
        XCTAssertFalse(monitor.hasHeardSpeech)
    }

    func testPauseShorterThanTheWindowDoesNotStop() {
        // A two-second pause for breath inside a three-second window. The
        // sentence continues; the capture must too.
        var monitor = CaptureEndPointingMonitor(silenceWindow: 3, maximumDuration: 600)
        _ = run(&monitor, from: 0, seconds: 2, speech: true)
        let pause = run(&monitor, from: 2, seconds: 2, speech: false)
        XCTAssertFalse(pause.contains { if case .stop = $0.decision { return true } else { return false } })
        let resumed = run(&monitor, from: 4, seconds: 2, speech: true)
        XCTAssertTrue(resumed.isEmpty)
        XCTAssertFalse(monitor.hasStopped)
    }

    func testRepeatedShortPausesNeverAccumulateIntoAStop() {
        // Halting speech: one second on, two seconds off, over and over. The
        // window must restart every time, never add up.
        var monitor = CaptureEndPointingMonitor(silenceWindow: 3, maximumDuration: 600)
        var time = 0.0
        for _ in 0..<10 {
            _ = run(&monitor, from: time, seconds: 1, speech: true)
            time += 1
            _ = run(&monitor, from: time, seconds: 2, speech: false)
            time += 2
        }
        XCTAssertFalse(monitor.hasStopped)
    }

    func testSingleSpeechSampleMidWindowResetsIt() {
        var monitor = CaptureEndPointingMonitor(silenceWindow: 3, maximumDuration: 600)
        _ = run(&monitor, from: 0, seconds: 1, speech: true)
        _ = run(&monitor, from: 1, seconds: 2.5, speech: false)
        XCTAssertEqual(monitor.observe(speechDetected: true, atSeconds: 3.5), .waiting)
        // The window restarts from here, so the old 2.5 s of silence is spent.
        let events = run(&monitor, from: 3.6, seconds: 2.5, speech: false)
        XCTAssertFalse(events.contains { if case .stop = $0.decision { return true } else { return false } })
    }

    // MARK: - Stopping

    func testStopsAfterTheWindowOfSilenceFollowingSpeech() {
        var monitor = CaptureEndPointingMonitor(silenceWindow: 3, maximumDuration: 600)
        _ = run(&monitor, from: 0, seconds: 2, speech: true)
        let events = run(&monitor, from: 2, seconds: 5, speech: false)
        let stop = events.first { if case .stop = $0.decision { return true } else { return false } }
        XCTAssertEqual(stop?.decision, .stop(.silence))
        // Silence began at t=2, so the stop lands one window later, not before.
        XCTAssertEqual(stop?.time ?? 0, 5, accuracy: 2 * step)
    }

    func testWarningPrecedesTheStopByTheLead() {
        var monitor = CaptureEndPointingMonitor(silenceWindow: 4, maximumDuration: 600)
        _ = run(&monitor, from: 0, seconds: 1, speech: true)
        let events = run(&monitor, from: 1, seconds: 6, speech: false)
        let warnings = events.filter { $0.decision == .warning }
        XCTAssertEqual(warnings.count, 1, "the warning is an edge, not a repeated state")
        let stop = events.first { if case .stop = $0.decision { return true } else { return false } }
        XCTAssertNotNil(stop)
        XCTAssertEqual(
            (stop?.time ?? 0) - (warnings.first?.time ?? 0),
            CaptureEndPointingPolicy.warningLeadSeconds,
            accuracy: 2 * step
        )
    }

    func testWarningIsRearmedWhenSpeechResumes() {
        var monitor = CaptureEndPointingMonitor(silenceWindow: 3, maximumDuration: 600)
        _ = run(&monitor, from: 0, seconds: 1, speech: true)
        let first = run(&monitor, from: 1, seconds: 2.2, speech: false)
        XCTAssertEqual(first.filter { $0.decision == .warning }.count, 1)
        _ = run(&monitor, from: 3.2, seconds: 1, speech: true)
        let second = run(&monitor, from: 4.2, seconds: 2.2, speech: false)
        XCTAssertEqual(second.filter { $0.decision == .warning }.count, 1)
    }

    // MARK: - The hot microphone

    func testMaximumDurationStopsACaptureThatNeverGoesQuiet() {
        // A noisy room: every sample reads as speech, so the silence window
        // never runs. The cap is the only thing that can end this.
        var monitor = CaptureEndPointingMonitor(silenceWindow: 3, maximumDuration: 20)
        let events = run(&monitor, from: 0, seconds: 30, speech: true)
        let stop = events.first { if case .stop = $0.decision { return true } else { return false } }
        XCTAssertEqual(stop?.decision, .stop(.maximumDuration))
        XCTAssertEqual(stop?.time ?? 0, 20, accuracy: 2 * step)
    }

    func testMaximumDurationStopsACaptureThatNeverHearsAnything() {
        // A dead microphone, or a level feed that never arrives: silence
        // forever and no speech ever heard. Rule 1 forbids a silence stop, so
        // the cap has to be what closes it.
        var monitor = CaptureEndPointingMonitor(silenceWindow: 3, maximumDuration: 15)
        let events = run(&monitor, from: 0, seconds: 25, speech: false)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.decision, .stop(.maximumDuration))
    }

    func testStopIsLatchedSoALateSampleCannotStopASecondTime() {
        var monitor = CaptureEndPointingMonitor(silenceWindow: 2, maximumDuration: 600)
        _ = run(&monitor, from: 0, seconds: 1, speech: true)
        let events = run(&monitor, from: 1, seconds: 10, speech: false)
        XCTAssertEqual(events.filter { if case .stop = $0.decision { return true } else { return false } }.count, 1)
        XCTAssertEqual(monitor.observe(speechDetected: false, atSeconds: 99), .waiting)
    }

    // MARK: - Hostile timelines

    func testTimelineGoingBackwardsOnlyRestartsTheWindow() {
        var monitor = CaptureEndPointingMonitor(silenceWindow: 3, maximumDuration: 600)
        _ = monitor.observe(speechDetected: true, atSeconds: 10)
        XCTAssertEqual(monitor.observe(speechDetected: false, atSeconds: 11), .waiting)
        // A sample from before the silence started must not be read as a
        // four-second-long silence.
        XCTAssertEqual(monitor.observe(speechDetected: false, atSeconds: 7), .waiting)
        XCTAssertFalse(monitor.hasStopped)
    }

    func testResetClearsEverything() {
        var monitor = CaptureEndPointingMonitor(silenceWindow: 2, maximumDuration: 600)
        _ = run(&monitor, from: 0, seconds: 1, speech: true)
        _ = run(&monitor, from: 1, seconds: 4, speech: false)
        XCTAssertTrue(monitor.hasStopped)
        monitor.reset()
        XCTAssertFalse(monitor.hasStopped)
        XCTAssertFalse(monitor.hasHeardSpeech)
        XCTAssertTrue(run(&monitor, from: 0, seconds: 10, speech: false).isEmpty)
    }

    // MARK: - Policy bounds

    func testConfiguredWindowIsClampedIntoRange() {
        XCTAssertEqual(CaptureEndPointingPolicy.silenceWindow(configured: 0.1), 2)
        XCTAssertEqual(CaptureEndPointingPolicy.silenceWindow(configured: 60), 8)
        XCTAssertEqual(CaptureEndPointingPolicy.silenceWindow(configured: 4), 4)
        XCTAssertEqual(
            CaptureEndPointingPolicy.silenceWindow(configured: .nan),
            CaptureEndPointingPolicy.defaultSilenceWindowSeconds
        )
    }

    func testConfiguredMaximumDurationIsClampedIntoRange() {
        XCTAssertEqual(CaptureEndPointingPolicy.maximumDuration(configured: 0), 5)
        XCTAssertEqual(CaptureEndPointingPolicy.maximumDuration(configured: 99_999), 3600)
        XCTAssertEqual(CaptureEndPointingPolicy.maximumDuration(configured: 300), 300)
    }

    func testAMonitorBuiltWithAnOutOfRangeWindowUsesTheClampedOne() {
        let monitor = CaptureEndPointingMonitor(silenceWindow: 0.2, maximumDuration: 1)
        XCTAssertEqual(monitor.silenceWindow, 2)
        XCTAssertEqual(monitor.maximumDuration, 5)
    }

    // MARK: - Level maths

    func testDigitalSilenceIsBelowTheThreshold() {
        let level = AudioLevelMeter.decibels(samples: [Float](repeating: 0, count: 512))
        XCTAssertEqual(level, AudioLevelMeter.silenceFloorDBFS)
        XCTAssertFalse(CaptureEndPointingPolicy.speechDetected(levelDBFS: level))
    }

    func testRoomToneIsBelowTheThresholdAndSpeechIsAboveIt() {
        // Room tone around -60 dBFS; a quiet voice around -30.
        XCTAssertFalse(CaptureEndPointingPolicy.speechDetected(levelDBFS: -60))
        XCTAssertTrue(CaptureEndPointingPolicy.speechDetected(levelDBFS: -30))
        XCTAssertTrue(CaptureEndPointingPolicy.speechDetected(levelDBFS: -6))
    }

    func testFullScaleIsZeroDecibels() {
        XCTAssertEqual(AudioLevelMeter.decibels(rms: 1), 0, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelMeter.decibels(rms: 0.1), -20, accuracy: 0.0001)
    }

    func testEmptyOrInvalidInputReadsAsSilenceRatherThanInfinity() {
        XCTAssertEqual(AudioLevelMeter.decibels(samples: [Float]()), AudioLevelMeter.silenceFloorDBFS)
        XCTAssertEqual(AudioLevelMeter.decibels(rms: -1), AudioLevelMeter.silenceFloorDBFS)
        XCTAssertEqual(AudioLevelMeter.decibels(rms: .nan), AudioLevelMeter.silenceFloorDBFS)
        XCTAssertTrue(AudioLevelMeter.decibels(rms: 0).isFinite)
    }

    func testAlternatingSineBlockReadsAsSpeech() {
        // A -20 dBFS tone: amplitude 0.1 sine has RMS 0.0707, about -23 dBFS.
        let samples = (0..<1024).map { Float(0.1 * sin(Double($0) * 0.1)) }
        let level = AudioLevelMeter.decibels(samples: samples)
        XCTAssertTrue(CaptureEndPointingPolicy.speechDetected(levelDBFS: level))
        XCTAssertLessThan(level, 0)
    }
}
