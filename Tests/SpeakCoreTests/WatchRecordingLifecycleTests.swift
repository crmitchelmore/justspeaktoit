import XCTest
@testable import SpeakCore

final class WatchRecordingLifecycleTests: XCTestCase {
    private let usableDuration: TimeInterval = 42

    // MARK: - Runtime loss keeps the partial capture

    func testRuntimeInvalidated_enqueuesThePartialCapture() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .runtimeInvalidated(reason: nil),
            duration: usableDuration,
            hasAudioFile: true
        )

        // The whole point of the extended-runtime work: a wrist-down recording
        // the OS cuts short still reaches iPhone history.
        XCTAssertEqual(outcome.disposition, .enqueue)
        XCTAssertNotNil(outcome.message, "The user should be told the capture was cut short")
    }

    func testInterruption_enqueuesThePartialCapture() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .interrupted,
            duration: usableDuration,
            hasAudioFile: true
        )

        XCTAssertEqual(outcome.disposition, .enqueue)
        XCTAssertNotNil(outcome.message)
    }

    func testRuntimeInvalidated_surfacesTheSystemReasonWhenGiven() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .runtimeInvalidated(reason: "Session expired"),
            duration: usableDuration,
            hasAudioFile: true
        )

        XCTAssertEqual(outcome.message, "Session expired")
    }

    // MARK: - Nothing worth sending

    func testRuntimeInvalidated_discardsWhenNoAudioWasWritten() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .runtimeInvalidated(reason: nil),
            duration: usableDuration,
            hasAudioFile: false
        )

        XCTAssertEqual(outcome.disposition, .discard)
        XCTAssertNotNil(outcome.message)
    }

    func testInterruption_discardsWhenItLandsBeforeAnyAudio() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .interrupted,
            duration: 0.05,
            hasAudioFile: true
        )

        XCTAssertEqual(outcome.disposition, .discard)
    }

    // MARK: - User-initiated stops

    func testUserStop_enqueuesSilently() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .userStopped,
            duration: usableDuration,
            hasAudioFile: true
        )

        XCTAssertEqual(outcome.disposition, .enqueue)
        XCTAssertNil(outcome.message, "A normal stop needs no explanation")
    }

    func testUserStop_discardsAnAccidentalTapSilently() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .userStopped,
            duration: 0.1,
            hasAudioFile: true
        )

        XCTAssertEqual(outcome.disposition, .discard)
        XCTAssertNil(outcome.message)
    }

    // MARK: - Duration threshold

    func testMinimumUsableDuration_isInclusive() {
        let atThreshold = WatchRecordingEndPolicy.outcome(
            for: .userStopped,
            duration: WatchRecordingEndPolicy.minimumUsableDuration,
            hasAudioFile: true
        )
        let belowThreshold = WatchRecordingEndPolicy.outcome(
            for: .userStopped,
            duration: WatchRecordingEndPolicy.minimumUsableDuration - 0.01,
            hasAudioFile: true
        )

        XCTAssertEqual(atThreshold.disposition, .enqueue)
        XCTAssertEqual(belowThreshold.disposition, .discard)
    }

    // MARK: - Encoder failure

    func testEncodingFailure_discardsEvenALongRecording() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .encodingFailed(reason: nil),
            duration: usableDuration,
            hasAudioFile: true
        )

        // The bytes on disk cannot be trusted, however long the capture ran.
        XCTAssertEqual(outcome.disposition, .discard)
        XCTAssertNotNil(outcome.message)
    }

    func testEncodingFailure_surfacesTheUnderlyingError() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .encodingFailed(reason: "Encoder ran out of space"),
            duration: usableDuration,
            hasAudioFile: true
        )

        XCTAssertEqual(outcome.message, "Encoder ran out of space")
    }

    // MARK: - Queue hand-off

    func testEnqueuedPartialCapture_startsInTheRecordedState() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .runtimeInvalidated(reason: nil),
            duration: usableDuration,
            hasAudioFile: true
        )

        XCTAssertEqual(outcome.disposition, .enqueue)
        // An enqueued capture enters the queue as `.recorded` and must be able
        // to walk the normal path to the iPhone from there.
        XCTAssertTrue(WatchCaptureStatus.recorded.canTransition(to: .transferring))
        XCTAssertTrue(WatchCaptureStatus.transferring.canTransition(to: .delivered))
    }
}
