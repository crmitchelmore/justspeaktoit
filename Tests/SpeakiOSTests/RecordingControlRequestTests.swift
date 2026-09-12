import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

final class RecordingControlRequestTests: XCTestCase {
    func testRequestedValues_preserveMeaningAcrossLifecycleAndSharedSnapshots() throws {
        for sharedFlag in [false, true] {
            for state: RecordingServiceState in [.starting, .recording] {
                for _ in 0..<2 {
                    XCTAssertEqual(try action(true, state, sharedFlag), .none)
                    XCTAssertEqual(try action(false, state, sharedFlag), .stop)
                }
            }
            XCTAssertEqual(try action(false, .stopping, sharedFlag), .none)
            XCTAssertThrowsError(try action(true, .stopping, sharedFlag)) { error in
                XCTAssertEqual(error as? RecordingControlRequest.RequestError, .recordingIsStopping)
            }
        }
        XCTAssertEqual(try action(true, .idle, false), .start)
        XCTAssertEqual(try action(false, .idle, false), .none)
    }

    func testInAppOwner_repeatedStartAndStopRequestsReportGuidance() {
        for requested in [true, true, false, false] {
            XCTAssertThrowsError(try action(requested, .idle, true)) { error in
                XCTAssertEqual(error as? RecordingControlRequest.RequestError, .alreadyRecordingInApp)
                XCTAssertEqual(error.localizedDescription,
                               "A recording is already in progress in the app. Use the in-app stop button.")
            }
        }
    }

    @MainActor
    func testFalseDuringStartup_cancelsAndPublishesCleanupBeforeRetry() async throws {
        let suite = "RecordingControlRequestTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var published: [Bool] = []
        let shared = SharedTranscriptionState(defaults: defaults, reloadRecordingControl: { _ in
            published.append(defaults.bool(forKey: "isRecording"))
        })
        let lifecycle = RecordingLifecycleCoordinator()
        let run = try XCTUnwrap(lifecycle.beginStart())
        shared.isRecording = true
        XCTAssertEqual(try action(true, lifecycle.state, shared.isRecording), .none)
        XCTAssertEqual(try action(false, lifecycle.state, shared.isRecording), .stop)
        lifecycle.retireStartRun()
        XCTAssertFalse(lifecycle.activate(run))
        XCTAssertNil(lifecycle.beginStart())

        // The existing startup owner performs this cleanup on failure/cancellation.
        shared.clearRecordingState()
        lifecycle.finishStartUnwind()
        await lifecycle.awaitStartSettled()
        XCTAssertEqual(published, [true, false])
        XCTAssertEqual(try action(false, lifecycle.state, shared.isRecording), .none)
        XCTAssertEqual(try action(true, lifecycle.state, shared.isRecording), .start)
    }

    @MainActor
    func testRepeatedValues_doNotReverseAchievedStateOrDuplicateStop() throws {
        let lifecycle = RecordingLifecycleCoordinator()
        XCTAssertEqual(try action(true, lifecycle.state, false), .start)
        let run = try XCTUnwrap(lifecycle.beginStart())
        XCTAssertTrue(lifecycle.activate(run))
        XCTAssertEqual(try action(true, lifecycle.state, true), .none)
        XCTAssertEqual(try action(false, lifecycle.state, true), .stop)
        XCTAssertTrue(lifecycle.beginStopping())
        XCTAssertEqual(try action(false, lifecycle.state, true), .none)
        lifecycle.finishStopping()
        XCTAssertEqual(try action(false, lifecycle.state, false), .none)
    }

    private func action(
        _ requested: Bool,
        _ state: RecordingServiceState,
        _ shared: Bool
    ) throws -> RecordingControlRequest.Action {
        try RecordingControlRequest.action(desiredValue: requested, serviceState: state, sharedIsRecording: shared)
    }
}
