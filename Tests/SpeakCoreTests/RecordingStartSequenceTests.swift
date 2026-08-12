import Foundation
import XCTest

@testable import SpeakCore

/// Regression cover for issue #641 — "clipped initial speech when recording
/// starts".
///
/// The audible start cue used to sound the instant the hot key was handled,
/// while the microphone capture path (permission refresh, preferred-input
/// selection, `AVAudioRecorder` warm-up and, for live modes, the audio-engine
/// tap) was still being brought up. Anything the user said in that window was
/// captured by nothing at all.
///
/// These tests pin the contract the fix relies on: the cue is an *effect of*
/// proven capture readiness, never a prediction of it.
@MainActor
final class RecordingStartSequenceTests: XCTestCase {

    /// Records the observable side effects of a start attempt, in order.
    private final class StartLog {
        private(set) var events: [String] = []
        func record(_ event: String) { self.events.append(event) }
    }

    /// Deterministic clock: each read advances by a fixed step so checkpoint
    /// offsets are exact rather than wall-clock flaky.
    private final class StepClock {
        private let base = Date(timeIntervalSince1970: 1_700_000_000)
        private let stepSeconds: TimeInterval
        private var reads = 0

        init(stepSeconds: TimeInterval) { self.stepSeconds = stepSeconds }

        func now() -> Date {
            defer { self.reads += 1 }
            return self.base.addingTimeInterval(self.stepSeconds * Double(self.reads))
        }
    }

    private struct StartFailure: Error {}

    // MARK: - Cue ordering

    func testCue_SoundsOnlyAfterLocalCaptureIsProvenReady() async throws {
        // Arrange
        let log = StartLog()
        let sequencer = RecordingStartSequencer(
            startCapture: { log.record("capture-ready") },
            startStream: nil,
            playCue: { log.record("cue") }
        )

        // Act
        let timeline = try await sequencer.run()

        // Assert
        XCTAssertEqual(log.events, ["capture-ready", "cue"])
        XCTAssertTrue(timeline.cueFollowedCaptureReadiness)
    }

    func testCue_WaitsForTheStreamingCaptureTapInLiveModes() async throws {
        // Arrange: live modes install the audio-engine tap in a second step,
        // which is where Deepgram Nova 3 streaming lost its opening syllable.
        let log = StartLog()
        let sequencer = RecordingStartSequencer(
            startCapture: { log.record("capture-ready") },
            startStream: { log.record("stream-ready") },
            playCue: { log.record("cue") }
        )

        // Act
        let timeline = try await sequencer.run()

        // Assert
        XCTAssertEqual(log.events, ["capture-ready", "stream-ready", "cue"])
        XCTAssertTrue(timeline.cueFollowedCaptureReadiness)
    }

    func testCue_NeverSoundsWhenLocalCaptureFailsToStart() async {
        // Arrange
        let log = StartLog()
        let sequencer = RecordingStartSequencer(
            startCapture: { throw StartFailure() },
            startStream: { log.record("stream-ready") },
            playCue: { log.record("cue") }
        )

        // Act / Assert
        do {
            _ = try await sequencer.run()
            XCTFail("Expected the capture failure to propagate")
        } catch {
            XCTAssertTrue(error is StartFailure)
        }
        XCTAssertEqual(log.events, [])
    }

    func testCue_NeverSoundsWhenTheStreamingTapFailsToStart() async {
        // Arrange
        let log = StartLog()
        let sequencer = RecordingStartSequencer(
            startCapture: { log.record("capture-ready") },
            startStream: { throw StartFailure() },
            playCue: { log.record("cue") }
        )

        // Act / Assert
        do {
            _ = try await sequencer.run()
            XCTFail("Expected the stream failure to propagate")
        } catch {
            XCTAssertTrue(error is StartFailure)
        }
        XCTAssertEqual(log.events, ["capture-ready"])
    }

    // MARK: - Timing diagnostics

    func testTimeline_ReportsCheckpointOffsetsFromTheTrigger() async throws {
        // Arrange: 40ms between every checkpoint read.
        let clock = StepClock(stepSeconds: 0.04)
        let sequencer = RecordingStartSequencer(
            now: clock.now,
            startCapture: {},
            startStream: {},
            playCue: {}
        )

        // Act
        let timeline = try await sequencer.run()

        // Assert
        XCTAssertEqual(timeline.offsetMilliseconds(of: .triggered), 0)
        XCTAssertEqual(timeline.offsetMilliseconds(of: .captureReady), 40)
        XCTAssertEqual(timeline.offsetMilliseconds(of: .streamReady), 80)
        XCTAssertEqual(timeline.offsetMilliseconds(of: .cuePlayed), 120)
        XCTAssertEqual(
            timeline.diagnosticSummary,
            "capture-ready 40 ms, stream-ready 80 ms, cue 120 ms"
        )
    }

    func testTimeline_OmitsTheStreamCheckpointForNonStreamingSessions() async throws {
        // Arrange
        let clock = StepClock(stepSeconds: 0.05)
        let sequencer = RecordingStartSequencer(
            now: clock.now,
            startCapture: {},
            startStream: nil,
            playCue: {}
        )

        // Act
        let timeline = try await sequencer.run()

        // Assert
        XCTAssertNil(timeline.offsetMilliseconds(of: .streamReady))
        XCTAssertEqual(timeline.diagnosticSummary, "capture-ready 50 ms, cue 100 ms")
    }

    func testTimeline_FlagsACueThatPrecededCaptureReadiness() {
        // Arrange: the pre-fix ordering, built by hand — the cue sounded first
        // and capture readiness landed afterwards.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var timeline = RecordingStartTimeline(triggeredAt: base)

        // Act
        timeline.mark(.cuePlayed, at: base.addingTimeInterval(0.001))
        timeline.mark(.captureReady, at: base.addingTimeInterval(0.180))

        // Assert
        XCTAssertFalse(timeline.cueFollowedCaptureReadiness)
    }
}
