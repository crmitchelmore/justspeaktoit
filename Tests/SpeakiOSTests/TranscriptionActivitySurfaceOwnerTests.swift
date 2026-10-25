#if os(iOS)
import ActivityKit
import Foundation
import XCTest
@testable import SpeakCore

@MainActor
final class TranscriptionActivitySurfaceOwnerTests: XCTestCase {
    func testPrivateOwnerMatchesSubmittedGenericResultWithoutPublishingCopyToken() throws {
        let activity = FakeActivity()
        let manager = self.makeManager(activity)
        defer { manager.endActivity() }
        let owner = UUID()
        XCTAssertTrue(manager.startActivity(provider: "Test"))
        manager.completeActivity(
            finalWordCount: 3, duration: 1, keepPrimed: true,
            completionOutcome: .ready, surfaceOwnerID: owner
        )
        XCTAssertTrue(manager.hasActiveResult(surfaceOwnerID: owner), "Submitted state precedes OS content")
        XCTAssertFalse(manager.hasActiveResult(surfaceOwnerID: UUID()))
        XCTAssertFalse(manager.hasActiveResult(completionID: ""))
        let state = try XCTUnwrap(manager.latestState)
        XCTAssertEqual(state.resultCompletionID, "")
        XCTAssertEqual(state.resultPreview, "")
        let row = try XCTUnwrap(TranscriptionResultRow(state: state))
        XCTAssertFalse(row.offersCopy)
        XCTAssertFalse(row.offersOpen)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(state), encoding: .utf8))
        XCTAssertFalse(encoded.contains(owner.uuidString))
        XCTAssertFalse(encoded.contains("surfaceOwner"))
        XCTAssertTrue(manager.startActivity(provider: "Reused"))
        XCTAssertFalse(manager.hasActiveResult(surfaceOwnerID: owner))
        let replacement = UUID()
        manager.completeActivity(
            finalWordCount: 1, duration: 1, keepPrimed: true,
            completionOutcome: .ready, surfaceOwnerID: replacement
        )
        XCTAssertFalse(manager.hasActiveResult(surfaceOwnerID: owner))
        XCTAssertTrue(manager.hasActiveResult(surfaceOwnerID: replacement))
        manager.completeActivity(finalWordCount: 1, duration: 1, keepPrimed: true, completionOutcome: .ready)
        XCTAssertFalse(manager.hasActiveResult(surfaceOwnerID: replacement), "Legacy completion cannot inherit owner")
    }

    func testGenericUpdatesErrorDismissalAndRetirementInvalidateOwnerWithoutRevival() {
        let activity = FakeActivity()
        let manager = self.makeManager(activity)
        defer { manager.endActivity() }
        let owner = UUID()
        XCTAssertTrue(manager.startActivity(provider: "Test"))
        func complete() {
            manager.completeActivity(
                finalWordCount: 1, duration: 1, keepPrimed: true,
                completionOutcome: .ready, surfaceOwnerID: owner
            )
            XCTAssertTrue(manager.hasActiveResult(surfaceOwnerID: owner))
        }
        complete()
        manager.updateActivity(status: .listening, lastSnippet: "", wordCount: 0, duration: 0)
        XCTAssertFalse(manager.hasActiveResult(surfaceOwnerID: owner))
        manager.updateActivity(status: .completed, lastSnippet: "", wordCount: 0, duration: 0)
        XCTAssertFalse(manager.hasActiveResult(surfaceOwnerID: owner), "Generic completed update cannot revive owner")
        complete()
        manager.reportError("Failed")
        XCTAssertFalse(manager.hasActiveResult(surfaceOwnerID: owner))
        complete()
        activity.activityState = .dismissed
        activity.observers.last?(.dismissed)
        XCTAssertFalse(manager.hasActiveResult(surfaceOwnerID: owner))
        activity.activityState = .active
        XCTAssertTrue(manager.startActivity(provider: "Replacement"))
        complete()
        manager.endActivity()
        XCTAssertFalse(manager.hasActiveResult(surfaceOwnerID: owner))
    }

    func testIdleResetAndNonretainedCompletionCannotKeepSurfaceOwner() async {
        let activity = FakeActivity()
        let sleeping = expectation(description: "owned result-row idle timer admitted")
        let clock = SurfaceOwnerSleep(entered: { sleeping.fulfill() })
        let manager = TranscriptionActivityManager(
            activitiesEnabled: { true }, activities: { [activity] }, request: { _ in activity },
            sleep: { try await clock.wait() }
        )
        defer { manager.endActivity(); clock.release() }
        let owner = UUID()
        XCTAssertTrue(manager.startActivity(provider: "Test"))
        manager.completeActivity(
            finalWordCount: 1, duration: 1, keepPrimed: true,
            completionOutcome: .ready, surfaceOwnerID: owner
        )
        XCTAssertTrue(manager.hasActiveResult(surfaceOwnerID: owner))
        guard await XCTWaiter.fulfillment(of: [sleeping], timeout: 2) == .completed else {
            return XCTFail("Idle timer did not register")
        }
        let idle = expectation(description: "owned timer submitted idle reset")
        activity.didUpdate = { state in if state.status == .idle { idle.fulfill() } }
        defer { activity.didUpdate = nil }
        clock.release()
        guard await XCTWaiter.fulfillment(of: [idle], timeout: 2) == .completed else {
            return XCTFail("Idle reset did not settle")
        }
        XCTAssertEqual(manager.latestState?.status, .idle)
        XCTAssertFalse(manager.hasActiveResult(surfaceOwnerID: owner))
        manager.completeActivity(
            finalWordCount: 1, duration: 1, keepPrimed: false,
            completionOutcome: .ready, surfaceOwnerID: owner
        )
        XCTAssertFalse(manager.hasActiveResult(surfaceOwnerID: owner))
    }

    private func makeManager(_ activity: FakeActivity) -> TranscriptionActivityManager {
        TranscriptionActivityManager(
            activitiesEnabled: { true }, activities: { [activity] }, request: { _ in activity },
            sleep: { _ in throw CancellationError() }
        )
    }
}

@MainActor
private final class SurfaceOwnerSleep {
    let entered: () -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var released = false
    init(entered: @escaping () -> Void) { self.entered = entered }
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            if self.released { continuation.resume() } else { self.continuation = continuation }
            self.entered()
        }
    }
    func release() {
        self.released = true
        self.continuation?.resume()
        self.continuation = nil
    }
}
#endif
