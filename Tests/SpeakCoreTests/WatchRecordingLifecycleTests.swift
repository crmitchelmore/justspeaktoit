import XCTest
@testable import SpeakCore

final class WatchRecordingLifecycleTests: XCTestCase {
    private let usableDuration: TimeInterval = 42

    private var capture: WatchActiveCapture {
        WatchActiveCapture(
            id: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/watch-capture.m4a"),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Runtime loss keeps the partial capture

    func testRuntimeInvalidated_enqueuesThePartialCapture() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .runtimeInvalidated(reason: nil),
            duration: usableDuration,
            hasPlayableAudio: true
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
            hasPlayableAudio: true
        )

        XCTAssertEqual(outcome.disposition, .enqueue)
        XCTAssertNotNil(outcome.message)
    }

    func testRuntimeInvalidated_surfacesTheSystemReasonWhenGiven() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .runtimeInvalidated(reason: "Session expired"),
            duration: usableDuration,
            hasPlayableAudio: true
        )

        XCTAssertEqual(outcome.message, "Session expired")
    }

    // MARK: - Nothing worth sending

    func testRuntimeInvalidated_discardsWhenNoAudioWasWritten() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .runtimeInvalidated(reason: nil),
            duration: usableDuration,
            hasPlayableAudio: false
        )

        XCTAssertEqual(outcome.disposition, .discard)
        XCTAssertNotNil(outcome.message)
    }

    func testInterruption_discardsWhenItLandsBeforeAnyAudio() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .interrupted,
            duration: 0.05,
            hasPlayableAudio: true
        )

        XCTAssertEqual(outcome.disposition, .discard)
    }

    // MARK: - User-initiated stops

    func testUserStop_enqueuesSilently() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .userStopped,
            duration: usableDuration,
            hasPlayableAudio: true
        )

        XCTAssertEqual(outcome.disposition, .enqueue)
        XCTAssertNil(outcome.message, "A normal stop needs no explanation")
    }

    func testUserStop_discardsAnAccidentalTapSilently() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .userStopped,
            duration: 0.1,
            hasPlayableAudio: true
        )

        XCTAssertEqual(outcome.disposition, .discard)
        XCTAssertNil(outcome.message)
    }

    // MARK: - Duration threshold

    func testMinimumUsableDuration_isInclusive() {
        let atThreshold = WatchRecordingEndPolicy.outcome(
            for: .userStopped,
            duration: WatchRecordingEndPolicy.minimumUsableDuration,
            hasPlayableAudio: true
        )
        let belowThreshold = WatchRecordingEndPolicy.outcome(
            for: .userStopped,
            duration: WatchRecordingEndPolicy.minimumUsableDuration - 0.01,
            hasPlayableAudio: true
        )

        XCTAssertEqual(atThreshold.disposition, .enqueue)
        XCTAssertEqual(belowThreshold.disposition, .discard)
    }

    // MARK: - Encoder failure

    func testSystemEndedRecording_usesPlayableAssetDurationWhenRecorderHasResetToZero() {
        let finalisation = WatchRecordingFinaliser.finalise(
            capture: capture,
            reason: .runtimeInvalidated(reason: nil),
            recorderDuration: 0,
            inspection: WatchAudioInspection(isPlayable: true, duration: usableDuration)
        )

        XCTAssertEqual(finalisation.duration, usableDuration)
        XCTAssertEqual(finalisation.outcome.disposition, .enqueue)
    }

    func testEncodingFailure_enqueuesAPlayablePrefix() {
        let finalisation = WatchRecordingFinaliser.finalise(
            capture: capture,
            reason: .encodingFailed(reason: "Encoder stopped."),
            recorderDuration: 0,
            inspection: WatchAudioInspection(isPlayable: true, duration: usableDuration)
        )

        XCTAssertEqual(finalisation.outcome.disposition, .enqueue)
        XCTAssertEqual(finalisation.duration, usableDuration)
        XCTAssertEqual(finalisation.outcome.message, "Encoder stopped. Sending what was captured.")
    }

    func testEncodingFailure_discardsAnUnplayableAsset() {
        let finalisation = WatchRecordingFinaliser.finalise(
            capture: capture,
            reason: .encodingFailed(reason: nil),
            recorderDuration: usableDuration,
            inspection: .unplayable
        )

        XCTAssertEqual(finalisation.outcome.disposition, .discard)
        XCTAssertNotNil(finalisation.outcome.message)
    }

    func testEncodingFailure_surfacesTheUnderlyingError() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .encodingFailed(reason: "Encoder ran out of space"),
            duration: usableDuration,
            hasPlayableAudio: false
        )

        XCTAssertEqual(outcome.message, "Encoder ran out of space")
    }

    // MARK: - Relaunch recovery

    func testPersistedActiveCapture_isRecoveredAfterRelaunchAndFinalisedFromTheAsset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let markerURL = directory.appendingPathComponent("active-capture.json")
        let originalRegistry = WatchActiveCaptureRegistry(fileURL: markerURL)
        let activeCapture = WatchActiveCapture(
            id: UUID(),
            fileURL: directory.appendingPathComponent("capture.m4a"),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try originalRegistry.persist(activeCapture)

        let relaunchedRegistry = WatchActiveCaptureRegistry(fileURL: markerURL)
        let recovered = try XCTUnwrap(relaunchedRegistry.load())
        let finalisation = WatchRecordingFinaliser.finalise(
            capture: recovered,
            reason: .runtimeInvalidated(reason: nil),
            recorderDuration: 0,
            inspection: WatchAudioInspection(isPlayable: true, duration: usableDuration)
        )

        XCTAssertEqual(recovered, activeCapture)
        XCTAssertEqual(finalisation.outcome.disposition, .enqueue)
        XCTAssertEqual(finalisation.duration, usableDuration)
        try relaunchedRegistry.clear(matching: activeCapture.id)
        XCTAssertNil(relaunchedRegistry.load())
        try FileManager.default.removeItem(at: directory)
    }

    func testFailedQueuePersistence_leavesActiveCaptureMarkerForNextLaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let markerURL = directory.appendingPathComponent("active-capture.json")
        let registry = WatchActiveCaptureRegistry(fileURL: markerURL)
        let activeCapture = WatchActiveCapture(
            id: UUID(),
            fileURL: directory.appendingPathComponent("capture.m4a"),
            startedAt: Date()
        )
        try registry.persist(activeCapture)

        var enqueueAttempts = 0
        let enqueued = try registry.clearAfterSuccessfulEnqueue(matching: activeCapture.id) {
            enqueueAttempts += 1
            return false
        }

        XCTAssertFalse(enqueued)
        XCTAssertEqual(enqueueAttempts, 1)
        XCTAssertEqual(registry.load(), activeCapture)
        try FileManager.default.removeItem(at: directory)
    }

    func testSuccessfulQueuePersistence_clearsActiveCaptureMarker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let markerURL = directory.appendingPathComponent("active-capture.json")
        let registry = WatchActiveCaptureRegistry(fileURL: markerURL)
        let activeCapture = WatchActiveCapture(
            id: UUID(),
            fileURL: directory.appendingPathComponent("capture.m4a"),
            startedAt: Date()
        )
        try registry.persist(activeCapture)

        let enqueued = try registry.clearAfterSuccessfulEnqueue(matching: activeCapture.id) { true }

        XCTAssertTrue(enqueued)
        XCTAssertNil(registry.load())
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Queue hand-off

    func testEnqueuedPartialCapture_startsInTheRecordedState() {
        let outcome = WatchRecordingEndPolicy.outcome(
            for: .runtimeInvalidated(reason: nil),
            duration: usableDuration,
            hasPlayableAudio: true
        )

        XCTAssertEqual(outcome.disposition, .enqueue)
        // An enqueued capture enters the queue as `.recorded` and must be able
        // to walk the normal path to the iPhone from there.
        XCTAssertTrue(WatchCaptureStatus.recorded.canTransition(to: .transferring))
        XCTAssertTrue(WatchCaptureStatus.transferring.canTransition(to: .delivered))
    }
}
