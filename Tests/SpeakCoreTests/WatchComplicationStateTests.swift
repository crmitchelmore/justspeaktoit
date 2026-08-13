import XCTest
@testable import SpeakCore

final class WatchComplicationStateTests: XCTestCase {
    // ISO8601 (the payload date format) has whole-second precision, so use a
    // whole-second date for round-trip equality checks.
    private let wholeSecondDate = Date(timeIntervalSince1970: 1_754_500_000)

    // MARK: - State mapping

    func testState_isIdleWithoutCaptures() {
        XCTAssertEqual(WatchComplicationState.state(isRecording: false, latestCaptureStatus: nil), .idle)
    }

    func testState_recordingWinsOverTheNewestCapture() {
        for status in WatchCaptureStatus.allCases {
            XCTAssertEqual(
                WatchComplicationState.state(isRecording: true, latestCaptureStatus: status),
                .recording,
                "recording must win over \(status.rawValue)"
            )
        }
        XCTAssertEqual(WatchComplicationState.state(isRecording: true, latestCaptureStatus: nil), .recording)
    }

    func testState_treatsEveryInFlightCaptureStatusAsSending() {
        for status in [WatchCaptureStatus.recorded, .transferring, .delivered] {
            XCTAssertEqual(
                WatchComplicationState.state(isRecording: false, latestCaptureStatus: status),
                .sending,
                "\(status.rawValue) is still on its way to the iPhone"
            )
        }
    }

    func testState_reportsHistoryAndFailureTerminalStates() {
        XCTAssertEqual(WatchComplicationState.state(isRecording: false, latestCaptureStatus: .transcribed), .inHistory)
        XCTAssertEqual(WatchComplicationState.state(isRecording: false, latestCaptureStatus: .failed), .failed)
    }

    func testEveryState_hasFaceRenderableContent() {
        for state in WatchComplicationState.allCases {
            XCTAssertFalse(state.symbolName.isEmpty)
            XCTAssertFalse(state.label.isEmpty)
            // Corner complications truncate hard, so keep the short label short.
            XCTAssertFalse(state.shortLabel.isEmpty)
            XCTAssertLessThanOrEqual(state.shortLabel.count, 8, "\(state.rawValue) short label is too long")
            XCTAssertFalse(state.recordingActionLabel.isEmpty)
            XCTAssertFalse(state.recordingActionHint.isEmpty)
        }
        XCTAssertEqual(WatchComplicationState.recording.recordingActionLabel, "Stop recording")
        XCTAssertEqual(WatchComplicationState.idle.recordingActionLabel, "Start recording")
    }

    func testRelevance_ranksInFlightStatesAboveIdle() {
        let idle = WatchComplicationState.idle
        XCTAssertEqual(idle.relevanceScore, 0, "idle relevance must remain neutral")
        for state in WatchComplicationState.allCases where state != idle {
            XCTAssertGreaterThan(state.relevanceScore, idle.relevanceScore, "\(state.rawValue) outranks idle")
            XCTAssertGreaterThan(state.relevanceDuration, 0)
        }
        let ranked: [WatchComplicationState] = [.recording, .sending, .inHistory, .idle]
        for (higher, lower) in zip(ranked, ranked.dropFirst()) {
            XCTAssertGreaterThan(higher.relevanceScore, lower.relevanceScore, "\(higher) outranks \(lower)")
        }
    }

    // MARK: - Snapshot payload

    func testSnapshot_roundTripsThroughTheSharedContainerPayload() throws {
        let snapshot = WatchComplicationSnapshot(
            state: .sending,
            updatedAt: wholeSecondDate,
            recordingStartedAt: wholeSecondDate,
            latestCaptureAt: wholeSecondDate,
            latestCaptureStatus: .failed,
            failureMessage: "Phone unavailable",
            expiresAt: wholeSecondDate.addingTimeInterval(300),
            inFlightCount: 2
        )

        let data = try XCTUnwrap(snapshot.encoded())
        let decoded = try XCTUnwrap(WatchComplicationSnapshot.decode(from: data))

        XCTAssertEqual(decoded, snapshot)
    }

    func testSnapshotDecoding_rejectsGarbageAndFutureSchemas() throws {
        XCTAssertNil(WatchComplicationSnapshot.decode(from: Data("not json".utf8)))

        let future = WatchComplicationSnapshot(
            state: .recording,
            updatedAt: wholeSecondDate,
            schemaVersion: WatchComplicationSnapshot.currentSchemaVersion + 1
        )
        let data = try XCTUnwrap(future.encoded())

        XCTAssertNil(WatchComplicationSnapshot.decode(from: data))
    }

    func testSnapshotIdle_isWhatAFaceShowsBeforeTheAppEverPublishes() {
        XCTAssertEqual(WatchComplicationSnapshot.idle.state, .idle)
        XCTAssertNil(WatchComplicationSnapshot.idle.latestCaptureAt)
        XCTAssertEqual(WatchComplicationSnapshot.idle.inFlightCount, 0)
    }

    // MARK: - Stale recording clamp

    func testSettled_keepsARecordingThatTheHeartbeatStillRefreshes() {
        let snapshot = WatchComplicationSnapshot(state: .recording, updatedAt: wholeSecondDate, inFlightCount: 1)

        // Anything within the clamp is a live recording: the app refreshes the
        // timestamp every `recordingHeartbeat` seconds while it records.
        for age in [0, 1, WatchComplicationSnapshot.recordingHeartbeat * 2] {
            let settled = snapshot.settled(now: wholeSecondDate.addingTimeInterval(age))
            XCTAssertEqual(settled.state, .recording, "a \(age)s old recording is still live")
        }
    }

    func testSettled_clearsARecordingLeftBehindByAStoppedApp() {
        let snapshot = WatchComplicationSnapshot(
            state: .recording,
            updatedAt: wholeSecondDate,
            recordingStartedAt: wholeSecondDate,
            latestCaptureAt: wholeSecondDate,
            expiresAt: wholeSecondDate.addingTimeInterval(WatchComplicationSnapshot.recordingStaleAfter),
            inFlightCount: 1
        )

        let stale = WatchComplicationSnapshot.recordingStaleAfter + 1
        let settled = snapshot.settled(now: wholeSecondDate.addingTimeInterval(stale))

        XCTAssertEqual(settled.state, .idle)
        XCTAssertNil(settled.recordingStartedAt)
        XCTAssertNil(settled.expiresAt)
        // Only the disbelieved state changes; the rest of the payload stands.
        XCTAssertEqual(settled.latestCaptureAt, snapshot.latestCaptureAt)
        XCTAssertEqual(settled.inFlightCount, snapshot.inFlightCount)
    }

    func testSettled_revealsTheLatestQueueStateBehindAStaleRecording() {
        let snapshot = WatchComplicationSnapshot(
            state: .recording,
            updatedAt: wholeSecondDate,
            latestCaptureStatus: .transferring,
            expiresAt: wholeSecondDate
        )

        XCTAssertEqual(
            snapshot.settled(now: wholeSecondDate.addingTimeInterval(1)).state,
            .sending
        )
    }

    func testSettled_leavesEveryOtherStateAlone() {
        let ancient = wholeSecondDate.addingTimeInterval(WatchComplicationSnapshot.recordingStaleAfter * 10)
        for state in WatchComplicationState.allCases where state != .recording {
            let snapshot = WatchComplicationSnapshot(state: state, updatedAt: wholeSecondDate)

            XCTAssertEqual(snapshot.settled(now: ancient).state, state, "\(state) does not go stale")
        }
    }

    func testStaleClamp_sitsWellAboveTheRecordingHeartbeat() {
        // A live recording must never trip the clamp between two heartbeats.
        XCTAssertGreaterThan(
            WatchComplicationSnapshot.recordingStaleAfter,
            WatchComplicationSnapshot.recordingHeartbeat * 4
        )
    }

    func testSettled_usesThePublishedExpiry() {
        let explicitExpiry = wholeSecondDate.addingTimeInterval(10)
        let snapshot = WatchComplicationSnapshot(
            state: .recording,
            updatedAt: wholeSecondDate,
            expiresAt: explicitExpiry
        )

        XCTAssertEqual(snapshot.settled(now: explicitExpiry).state, .recording)
        XCTAssertEqual(snapshot.settled(now: explicitExpiry.addingTimeInterval(1)).state, .idle)
    }

    // MARK: - Record request

    func testRecordingRequest_roundTrips() throws {
        let request = WatchRecordingRequest(id: UUID(), requestedAt: wholeSecondDate)

        let data = try XCTUnwrap(request.encoded())
        let decoded = try XCTUnwrap(WatchRecordingRequest.decode(from: data))

        XCTAssertEqual(decoded, request)
    }

    func testRecordingRequest_goesStaleSoAQueuedTapCannotRecordLater() {
        let request = WatchRecordingRequest(requestedAt: wholeSecondDate)

        XCTAssertTrue(request.isFresh(now: wholeSecondDate))
        XCTAssertTrue(request.isFresh(now: wholeSecondDate.addingTimeInterval(5)))
        XCTAssertFalse(request.isFresh(now: wholeSecondDate.addingTimeInterval(60)))
        // A backwards clock jump must not resurrect an old tap either.
        XCTAssertFalse(request.isFresh(now: wholeSecondDate.addingTimeInterval(-60)))
    }

    func testRecordingRequestDecoding_rejectsFutureSchemas() throws {
        let future = WatchRecordingRequest(
            requestedAt: wholeSecondDate,
            schemaVersion: WatchRecordingRequest.currentSchemaVersion + 1
        )
        let data = try XCTUnwrap(future.encoded())

        XCTAssertNil(WatchRecordingRequest.decode(from: data))
    }
}
