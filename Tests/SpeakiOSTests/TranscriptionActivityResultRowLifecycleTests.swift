#if os(iOS)
import ActivityKit
import XCTest
@testable import SpeakCore

// The result row (#1071) on top of the run-isolated lifecycle (#932): the
// completed row's state, the Copy receipt bound to its completion, and the
// provider a run publishes while its first write is still in flight.
extension TranscriptionActivityLifecycleTests {
    func testCompletionOutcomePublishesResultRowAndCopyMarksOnlyThatCompletion() async {
        let activity = FakeActivity()
        let manager = makeManager(activity)
        XCTAssertTrue(manager.startActivity(provider: "Test"))
        manager.completeActivity(
            finalWordCount: 3, duration: 2, keepPrimed: true,
            completionOutcome: .ready, resultPreview: "Hello there", resultCompletionID: "abc"
        )
        await waitUntil { activity.updates.last?.status == .completed }
        XCTAssertEqual(activity.updates.last?.completionOutcome, .ready)
        XCTAssertEqual(activity.updates.last?.resultPreview, "Hello there")
        XCTAssertEqual(activity.updates.last?.resultCompletionID, "abc")
        XCTAssertEqual(activity.updates.last?.lastSnippet, TranscriptionCompletionOutcome.ready.message)
        let mismatched = await manager.markCompletionCopied(completionID: "other")
        XCTAssertFalse(mismatched)
        let copied = await manager.markCompletionCopied(completionID: "abc")
        XCTAssertTrue(copied)
        await waitUntil { activity.updates.last?.completionOutcome == .copied }
        XCTAssertEqual(activity.updates.last?.resultCompletionID, "abc")
        XCTAssertEqual(activity.updates.last?.lastSnippet, TranscriptionCompletionOutcome.copied.message)
        XCTAssertTrue(manager.isActivityRunning)
        manager.endActivity()
    }

    func testCopyCannotRelabelARecordingThatRestartedOverTheRow() async {
        let activity = FakeActivity()
        let manager = makeManager(activity)
        XCTAssertTrue(manager.startActivity(provider: "First"))
        manager.completeActivity(
            finalWordCount: 3, duration: 2, keepPrimed: true, completionOutcome: .ready, resultCompletionID: "abc"
        )
        await waitUntil { activity.updates.last?.status == .completed }
        // The row is still on screen while the next run's first write is in flight.
        activity.suspendUpdates = true
        XCTAssertTrue(manager.startActivity(provider: "Second"))
        await waitUntil { activity.updateWaiter != nil }
        let copied = await manager.markCompletionCopied(completionID: "abc")
        XCTAssertFalse(copied)
        activity.suspendUpdates = false
        activity.updateWaiter?.resume()
        activity.updateWaiter = nil
        await drainTasks()
        XCTAssertEqual(activity.updates.last?.status, .recording)
        XCTAssertFalse(activity.updates.contains { $0.completionOutcome == .copied })
        manager.endActivity()
    }

    func testUpdatesUseTheRunsOwnProviderWhileItsFirstWriteIsInFlight() async {
        let activity = FakeActivity()
        activity.transcriptionState = TranscriptionActivityAttributes.ContentState(provider: "First")
        activity.suspendUpdates = true
        let manager = makeManager(activity)
        XCTAssertTrue(manager.startActivity(provider: "Second"))
        await waitUntil { activity.updateWaiter != nil }
        manager.updateActivity(status: .listening, lastSnippet: "hi", wordCount: 1, duration: 1)
        activity.suspendUpdates = false
        activity.updateWaiter?.resume()
        activity.updateWaiter = nil
        await waitUntil { activity.updates.last?.status == .listening }
        XCTAssertEqual(activity.updates.map(\.provider), ["Second", "Second"])
        manager.endActivity()
    }
}
#endif
