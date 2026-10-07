import Foundation
import XCTest

@testable import SpeakCore

/// Regression cover for a ~3 s hot-key → stream-start stall.
///
/// On a Bluetooth input (AirPods, 24 kHz) every live session's stream-ready —
/// and so the start cue — landed ~3.2 s after the hot key, because the live
/// engine's input node was built only after the recorder had opened the
/// microphone. Core Audio then waited for the route the recorder had just
/// changed to settle. Built first, the same input takes ~100–300 ms.
@MainActor
final class RecordingStartLiveInputPreparationTests: XCTestCase {

    private final class StartLog {
        private(set) var events: [String] = []
        func record(_ event: String) { self.events.append(event) }
    }

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

    private final class MutableFlag {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    private struct StartFailure: Error {}

    func testLiveInput_IsPreparedBeforeLocalCaptureOpensTheMicrophone() async throws {
        // Arrange
        let log = StartLog()
        let sequencer = RecordingStartSequencer(
            prepareStream: { log.record("stream-input-prepared") },
            startCapture: { log.record("capture-ready") },
            startStream: { log.record("stream-ready") },
            playCue: { log.record("cue") }
        )

        // Act
        let timeline = try await sequencer.run()

        // Assert
        XCTAssertEqual(log.events, ["stream-input-prepared", "capture-ready", "stream-ready", "cue"])
        XCTAssertTrue(timeline.streamInputPrecededCapture)
        XCTAssertTrue(timeline.cueFollowedCaptureReadiness)
    }

    func testLiveInput_IsNotPreparedForNonStreamingSessions() async throws {
        // Arrange: batch sessions have no live engine to hand an input to.
        let log = StartLog()
        let sequencer = RecordingStartSequencer(
            prepareStream: { log.record("stream-input-prepared") },
            startCapture: { log.record("capture-ready") },
            startStream: nil,
            playCue: { log.record("cue") }
        )

        // Act
        let timeline = try await sequencer.run()

        // Assert
        XCTAssertEqual(log.events, ["capture-ready", "cue"])
        XCTAssertNil(timeline.offsetMilliseconds(of: .streamInputPrepared))
        XCTAssertTrue(timeline.streamInputPrecededCapture)
    }

    func testLiveInput_PreparationFailure_OpensNoCaptureAndSkipsTheCue() async {
        // Arrange
        let log = StartLog()
        let sequencer = RecordingStartSequencer(
            prepareStream: { throw StartFailure() },
            startCapture: { log.record("capture-ready") },
            startStream: { log.record("stream-ready") },
            playCue: { log.record("cue") }
        )

        // Act / Assert
        do {
            _ = try await sequencer.run()
            XCTFail("Expected the preparation failure to propagate")
        } catch {
            XCTAssertTrue(error is StartFailure)
        }
        XCTAssertEqual(log.events, [])
    }

    func testStop_DuringLiveInputPreparation_ReleasesItAndOpensNoCapture() async {
        // Arrange
        let log = StartLog()
        let sessionIsCurrent = MutableFlag(true)
        let sequencer = RecordingStartSequencer(
            isSessionCurrent: { sessionIsCurrent.value },
            prepareStream: {
                log.record("stream-input-prepared")
                sessionIsCurrent.value = false
            },
            discardPreparedStream: { log.record("stream-input-released") },
            startCapture: { log.record("capture-ready") },
            discardCapture: { log.record("capture-discarded") },
            startStream: { log.record("stream-ready") },
            playCue: { log.record("cue") }
        )

        // Act / Assert
        do {
            _ = try await sequencer.run()
            XCTFail("Expected the abandoned start to abort")
        } catch {
            XCTAssertEqual(error as? RecordingStartAbort, .sessionEnded)
        }
        XCTAssertEqual(log.events, ["stream-input-prepared", "stream-input-released"])
    }

    func testStop_DuringStreamStart_ReleasesThePreparedInputLast() async {
        // Arrange
        let log = StartLog()
        let sessionIsCurrent = MutableFlag(true)
        let sequencer = RecordingStartSequencer(
            isSessionCurrent: { sessionIsCurrent.value },
            prepareStream: { log.record("stream-input-prepared") },
            discardPreparedStream: { log.record("stream-input-released") },
            startCapture: { log.record("capture-ready") },
            discardCapture: { log.record("capture-discarded") },
            startStream: {
                log.record("stream-ready")
                sessionIsCurrent.value = false
            },
            discardStream: { log.record("stream-discarded") },
            playCue: { log.record("cue") }
        )

        // Act / Assert
        do {
            _ = try await sequencer.run()
            XCTFail("Expected the abandoned start to abort")
        } catch {
            XCTAssertEqual(error as? RecordingStartAbort, .sessionEnded)
        }
        XCTAssertEqual(
            log.events,
            [
                "stream-input-prepared", "capture-ready", "stream-ready",
                "stream-discarded", "capture-discarded", "stream-input-released"
            ]
        )
    }

    func testTimeline_FlagsAStreamWhoseInputWasBuiltAfterCapture() {
        // Arrange: the pre-fix ordering — capture, then the live input.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var timeline = RecordingStartTimeline(triggeredAt: base)

        // Act
        timeline.mark(.captureReady, at: base.addingTimeInterval(0.064))
        timeline.mark(.streamReady, at: base.addingTimeInterval(3.2))

        // Assert
        XCTAssertFalse(timeline.streamInputPrecededCapture)
    }

    func testTimeline_ReportsTheInputPreparationCheckpoint() async throws {
        // Arrange
        let clock = StepClock(stepSeconds: 0.04)
        let sequencer = RecordingStartSequencer(
            now: clock.now,
            prepareStream: {},
            startCapture: {},
            startStream: {},
            playCue: {}
        )

        // Act
        let timeline = try await sequencer.run()

        // Assert
        XCTAssertEqual(
            timeline.diagnosticSummary,
            "input-prepared 40 ms, capture-ready 80 ms, stream-ready 120 ms, cue 160 ms"
        )
    }
}
