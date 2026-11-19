#if os(iOS) && DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit
import XCTest
@testable import SpeakCore
@testable import SpeakiOSLib

/// The app's Live Activities setting decides whether a finished capture keeps a
/// result row on screen, which in turn decides whether the Transcript Ready
/// alert may show (#1017).
@MainActor
final class RecordingServiceLiveActivitySettingTests: XCTestCase {
    func testSettingOff_BackgroundRequiredActivityEndsAtFinalisationAndAlertIsEligible() async throws {
        let capture = try BackgroundCapture(liveActivitiesEnabled: false)
        let (harness, activity, manager) = (capture.harness, capture.activity, capture.manager)
        defer { harness.cleanUp(); manager.endActivity() }
        let service = harness.makeService(activity: .live(manager))

        try await service.startRecording(requiresLiveActivity: true)
        XCTAssertNotNil(manager.activity, "iOS still requires an activity to start background capture")
        _ = await service.stopRecording(destination: .historyOnly)
        for _ in 0..<20 where activity.endCount == 0 { await Task.yield() }

        XCTAssertNil(manager.activity, "No activity may linger once the result is final")
        XCTAssertEqual(activity.endCount, 1)
        XCTAssertNotEqual(activity.transcriptionState.status, .completed, "No result row was published")
        let input = try XCTUnwrap(harness.notifications.first)
        XCTAssertFalse(input.matchingResultActivity)
        XCTAssertTrue(input.isEligible)
        XCTAssertEqual(input.historyID, harness.history.items.first?.id)
    }

    func testSettingOn_ResultRowStaysAndSuppressesAlertAsBefore() async throws {
        let capture = try BackgroundCapture(liveActivitiesEnabled: true)
        let (harness, activity, manager) = (capture.harness, capture.activity, capture.manager)
        defer { harness.cleanUp(); manager.endActivity() }
        let service = harness.makeService(activity: .live(manager))

        try await service.startRecording(requiresLiveActivity: true)
        _ = await service.stopRecording(destination: .historyOnly)

        XCTAssertNotNil(manager.activity)
        XCTAssertEqual(activity.endCount, 0)
        XCTAssertEqual(manager.latestState?.status, .completed)
        let input = try XCTUnwrap(harness.notifications.first)
        XCTAssertTrue(input.matchingResultActivity)
        XCTAssertFalse(input.isEligible)
    }

    func testSettingOff_ForegroundStartRequestsNoActivity() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.settings.liveActivitiesEnabled = false
        harness.defaults.set("Foreground words", forKey: "simulatorValidationTranscript")
        let service = harness.makeService()

        try await service.startRecording(requiresLiveActivity: true)
        XCTAssertTrue(service.isRunning)
        XCTAssertTrue(harness.activityStarts.isEmpty)
        _ = await service.stopRecording(destination: .historyOnly)
        XCTAssertTrue(harness.completions.isEmpty)
        XCTAssertEqual(harness.history.items.map(\.transcription), ["Foreground words"])
    }
}

@MainActor
private struct BackgroundCapture {
    let harness: DependencyHarness
    let activity = FakeActivity()
    let manager: TranscriptionActivityManager

    init(liveActivitiesEnabled: Bool) throws {
        harness = try DependencyHarness()
        harness.applicationState = .background
        harness.settings.liveActivitiesEnabled = liveActivitiesEnabled
        harness.defaults.set("Background words", forKey: "simulatorValidationTranscript")
        let activity = self.activity
        manager = TranscriptionActivityManager(
            activitiesEnabled: { true }, activities: { [activity] }, request: { _ in activity },
            sleep: { _ in throw CancellationError() }
        )
    }
}
#endif
