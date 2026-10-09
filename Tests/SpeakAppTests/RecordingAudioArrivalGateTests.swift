import XCTest

@testable import SpeakApp

/// The HUD clock and start cue must wait until the microphone delivers real
/// audio. A Bluetooth headset switching into call mode emits exact digital
/// zeros (-160 dB) for ~0.5–0.7 s after capture "starts"; counting that time,
/// or inviting speech with the cue, lost the user's first words.
final class RecordingAudioArrivalGateTests: XCTestCase {
  private let captureStarted = Date(timeIntervalSinceReferenceDate: 1_000)
  private let digitalSilence: Float = -160
  private let roomNoise: Float = -72

  func testDigitalSilence_holdsClockUntilRealAudio() {
    var gate = RecordingAudioArrivalGate(captureStarted: captureStarted)

    XCTAssertEqual(gate.observe(peakDecibels: digitalSilence, at: captureStarted.addingTimeInterval(0.2)), [])
    XCTAssertEqual(gate.observe(peakDecibels: digitalSilence, at: captureStarted.addingTimeInterval(0.6)), [])
    XCTAssertNil(gate.arrival)

    XCTAssertEqual(gate.observe(peakDecibels: roomNoise, at: captureStarted.addingTimeInterval(0.7)), [.startClock])
    XCTAssertEqual(gate.arrival, .signal)
  }

  func testRealAudio_startsClockOnFirstReading() {
    var gate = RecordingAudioArrivalGate(captureStarted: captureStarted)
    XCTAssertEqual(gate.observe(peakDecibels: roomNoise, at: captureStarted), [.startClock])
  }

  func testArrival_isReportedOnlyOnce() {
    var gate = RecordingAudioArrivalGate(captureStarted: captureStarted)
    _ = gate.observe(peakDecibels: roomNoise, at: captureStarted)
    XCTAssertEqual(gate.observe(peakDecibels: roomNoise, at: captureStarted.addingTimeInterval(0.1)), [])
  }

  func testSilentInput_fallsBackSoClockAlwaysStarts() {
    var gate = RecordingAudioArrivalGate(captureStarted: captureStarted)
    let justBefore = captureStarted.addingTimeInterval(RecordingAudioArrivalGate.fallbackDelay - 0.01)
    XCTAssertEqual(gate.observe(peakDecibels: digitalSilence, at: justBefore), [])

    let deadline = captureStarted.addingTimeInterval(RecordingAudioArrivalGate.fallbackDelay)
    XCTAssertEqual(gate.observe(peakDecibels: digitalSilence, at: deadline), [.startClock])
    XCTAssertEqual(gate.arrival, .fallback)
  }

  func testFallbackDelay_outlastsHeadsetSwitchWithoutReadingAsAHang() {
    // A longer wait would read as a hang; the cold AirPods switch is ~0.7 s.
    XCTAssertLessThanOrEqual(RecordingAudioArrivalGate.fallbackDelay, 1.5)
    XCTAssertGreaterThan(RecordingAudioArrivalGate.fallbackDelay, 0.7)
  }

  func testUnmeteredInput_countsAsArrived() {
    var gate = RecordingAudioArrivalGate(captureStarted: captureStarted)
    XCTAssertEqual(gate.observe(peakDecibels: nil, at: captureStarted), [.startClock])
  }

  func testCueRequestedBeforeAudio_waitsForArrival() {
    var gate = RecordingAudioArrivalGate(captureStarted: captureStarted)
    XCTAssertEqual(gate.requestCue(), [], "The cue must not invite speech into a silent microphone")
    XCTAssertEqual(
      gate.observe(peakDecibels: roomNoise, at: captureStarted.addingTimeInterval(0.6)),
      [.startClock, .playCue]
    )
  }

  func testCueRequestedAfterAudio_playsImmediately() {
    var gate = RecordingAudioArrivalGate(captureStarted: captureStarted)
    _ = gate.observe(peakDecibels: roomNoise, at: captureStarted)
    XCTAssertEqual(gate.requestCue(), [.playCue])
    XCTAssertEqual(gate.requestCue(), [], "The cue plays once")
  }
}
