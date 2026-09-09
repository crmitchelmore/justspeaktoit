#if os(iOS)
import ActivityKit
import XCTest
@testable import SpeakCore

@MainActor
final class TranscriptionActivityLifecycleTests: XCTestCase {
    func testActiveReuseAndInvalidCacheSearchAllCandidates() async {
        let cached = FakeActivity()
        let active = FakeActivity()
        let ended = FakeActivity(state: .ended)
        var candidates = [cached]
        var requests = 0
        let manager = TranscriptionActivityManager(
            activitiesEnabled: { true }, activities: { candidates },
            request: { _ in requests += 1; return FakeActivity() }
        )
        XCTAssertTrue(manager.startActivity(provider: "First"))
        await waitUntil { cached.updates.count == 1 }
        cached.activityState = .dismissed
        candidates = [ended, active]
        XCTAssertTrue(manager.startActivity(provider: "Second"))
        await waitUntil { active.updates.count == 1 }
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(active.updates.last?.provider, "Second")
        XCTAssertTrue(manager.isActivityRunning)
        manager.endActivity()
    }

    func testInvalidActivitiesRequestNewAndFailureCanRecover() {
        for invalidState in [ActivityState.stale, .ended, .dismissed] {
            var shouldFail = true
            var requests = 0
            let manager = TranscriptionActivityManager(
                activitiesEnabled: { true }, activities: { [FakeActivity(state: invalidState)] },
                request: { _ in
                    requests += 1
                    if shouldFail { throw TestError.unavailable }
                    return FakeActivity()
                }
            )
            XCTAssertFalse(manager.startActivity(provider: "Test"))
            XCTAssertFalse(manager.isActivityRunning)
            shouldFail = false
            XCTAssertTrue(manager.startActivity(provider: "Test"))
            XCTAssertTrue(manager.isActivityRunning)
            XCTAssertEqual(requests, 2)
            manager.endActivity()
        }
    }

    func testDisabledActivitiesNeverRequestAndClearCachedRunningState() {
        var enabled = true
        var requests = 0
        let manager = TranscriptionActivityManager(
            activitiesEnabled: { enabled }, activities: { [FakeActivity()] },
            request: { _ in requests += 1; return FakeActivity() }
        )
        XCTAssertTrue(manager.startActivity(provider: "Test"))
        enabled = false
        XCTAssertFalse(manager.startActivity(provider: "Test"))
        XCTAssertFalse(manager.isActivityRunning)
        XCTAssertEqual(requests, 0)
    }

    func testDismissalInvalidatesCurrentButOldObserverCannotClearReusedRun() {
        let activity = FakeActivity()
        let manager = makeManager(activity)
        XCTAssertTrue(manager.startActivity(provider: "First"))
        let oldObserver = activity.observers[0]
        XCTAssertTrue(manager.startActivity(provider: "Second"))
        oldObserver(.dismissed)
        XCTAssertTrue(manager.isActivityRunning)
        activity.activityState = .dismissed
        activity.observers.last?(.dismissed)
        XCTAssertFalse(manager.isActivityRunning)
    }

    func testOldObserverCannotClearReplacement() {
        let old = FakeActivity()
        let replacement = FakeActivity()
        var candidates = [old]
        let manager = TranscriptionActivityManager(
            activitiesEnabled: { true }, activities: { candidates }, request: { _ in replacement }
        )
        XCTAssertTrue(manager.startActivity(provider: "First"))
        old.activityState = .ended
        candidates = [replacement]
        XCTAssertTrue(manager.startActivity(provider: "Second"))
        old.observers[0](.ended)
        XCTAssertTrue(manager.isActivityRunning)
        manager.endActivity()
    }

    func testCompletionDelayCannotOverwriteRestartedRecordingOnSameActivity() async {
        let activity = FakeActivity()
        let sleeper = SuspendedSleep()
        let manager = makeManager(activity, sleeper: sleeper)
        XCTAssertTrue(manager.startActivity(provider: "First"))
        manager.completeActivity(finalWordCount: 4, duration: 2, keepPrimed: true)
        await waitUntil { sleeper.waiters.count == 1 }
        XCTAssertEqual(activity.updates.last?.status, .completed)
        XCTAssertTrue(manager.startActivity(provider: "Second"))
        await waitUntil { activity.updates.last?.provider == "Second" }
        sleeper.resumeAll()
        await drainTasks()
        XCTAssertEqual(activity.updates.last?.status, .recording)
        XCTAssertFalse(activity.updates.contains { $0.status == .idle })
        manager.endActivity()
    }

    func testCompletionRejectsInactiveActivityBeforeObserverDeliversState() {
        for state in [ActivityState.stale, .ended, .dismissed] {
            let activity = FakeActivity()
            let manager = makeManager(activity)
            XCTAssertTrue(manager.startActivity(provider: "Test"))
            activity.activityState = state
            manager.completeActivity(finalWordCount: 2, duration: 1, keepPrimed: true)
            XCTAssertFalse(manager.isActivityRunning)
            XCTAssertTrue(activity.updates.isEmpty)
        }
    }

    func testUninterruptedPrimedCompletionReturnsToIdle() async {
        let activity = FakeActivity()
        let sleeper = SuspendedSleep()
        let manager = makeManager(activity, sleeper: sleeper)
        XCTAssertTrue(manager.startActivity(provider: "Test"))
        manager.completeActivity(finalWordCount: 2, duration: 1, keepPrimed: true)
        await waitUntil { sleeper.waiters.count == 1 }
        sleeper.resumeAll()
        await waitUntil { activity.updates.last?.status == .idle }
        XCTAssertTrue(manager.isActivityRunning)
        manager.endActivity()
    }

    func testThrottledOldRunCannotPublishAfterRestart() async {
        let activity = FakeActivity()
        let sleeper = SuspendedSleep()
        let manager = makeManager(activity, sleeper: sleeper)
        XCTAssertTrue(manager.startActivity(provider: "First"))
        manager.updateActivity(status: .listening, lastSnippet: "first", wordCount: 1, duration: 1)
        manager.updateActivity(status: .processing, lastSnippet: "old deferred", wordCount: 2, duration: 2)
        await waitUntil { sleeper.waiters.count == 1 }
        XCTAssertTrue(manager.startActivity(provider: "Second"))
        sleeper.resumeAll()
        await waitUntil { activity.updates.last?.provider == "Second" }
        await drainTasks()
        XCTAssertEqual(activity.updates.last?.status, .recording)
        XCTAssertFalse(activity.updates.contains { $0.lastSnippet == "old deferred" })
        manager.endActivity()
    }

    func testInFlightUpdateFinishesBeforeRestartPublishesRecording() async {
        let activity = FakeActivity()
        activity.suspendUpdates = true
        let manager = makeManager(activity)
        XCTAssertTrue(manager.startActivity(provider: "First"))
        await waitUntil { activity.updateWaiter != nil }
        XCTAssertTrue(manager.startActivity(provider: "Second"))
        activity.suspendUpdates = false
        activity.updateWaiter?.resume()
        activity.updateWaiter = nil
        await waitUntil { activity.updates.last?.provider == "Second" }
        XCTAssertEqual(activity.updates.map(\.provider), ["First", "Second"])
        manager.endActivity()
    }

    func testNonPrimedCompletionAndImmediateEndCannotRetireReplacement() async {
        for complete in [true, false] {
            let old = FakeActivity()
            old.suspendEnd = true
            let replacement = FakeActivity()
            let manager = TranscriptionActivityManager(
                activitiesEnabled: { true }, activities: { [old] }, request: { _ in replacement }
            )
            XCTAssertTrue(manager.startActivity(provider: "First"))
            if complete {
                manager.completeActivity(finalWordCount: 1, duration: 1)
            } else {
                manager.endActivity()
            }
            XCTAssertFalse(manager.isActivityRunning)
            // ActivityKit still lists the old activity as active while end is suspended.
            XCTAssertTrue(manager.startActivity(provider: "Second"))
            await waitUntil { old.endWaiter != nil }
            old.endWaiter?.resume()
            old.endWaiter = nil
            await waitUntil { old.activityState == .ended }
            XCTAssertTrue(manager.isActivityRunning)
            XCTAssertEqual(replacement.endCount, 0)
            XCTAssertEqual(old.endCount, 1)
            manager.endActivity()
        }
    }

    private func makeManager(
        _ activity: FakeActivity, sleeper: SuspendedSleep? = nil
    ) -> TranscriptionActivityManager {
        let sleeper = sleeper ?? SuspendedSleep()
        return TranscriptionActivityManager(
            activitiesEnabled: { true }, activities: { [activity] }, request: { _ in FakeActivity() },
            sleep: { await sleeper.sleep($0) }
        )
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Asynchronous lifecycle operation did not settle", file: file, line: line)
    }

    private func drainTasks() async {
        for _ in 0..<30 { await Task.yield() }
    }
}

private enum TestError: Error { case unavailable }

@MainActor
private final class SuspendedSleep {
    var waiters: [CheckedContinuation<Void, Never>] = []
    func sleep(_ seconds: TimeInterval) async {
        // Deliberately ignore cancellation to prove the run guard also rejects stale work.
        await withCheckedContinuation { waiters.append($0) }
    }
    func resumeAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class FakeActivity: TranscriptionActivityHandle {
    let id = UUID().uuidString
    var nativeActivity: Activity<TranscriptionActivityAttributes>? { nil }
    var activityState: ActivityState
    var transcriptionState = TranscriptionActivityAttributes.ContentState()
    var updates: [TranscriptionActivityAttributes.ContentState] = []
    var observers: [@MainActor (ActivityState) -> Void] = []
    var suspendUpdates = false
    var updateWaiter: CheckedContinuation<Void, Never>?
    var suspendEnd = false
    var endWaiter: CheckedContinuation<Void, Never>?
    var endCount = 0

    init(state: ActivityState = .active) { activityState = state }

    func updateTranscription(_ state: TranscriptionActivityAttributes.ContentState) async {
        if suspendUpdates { await withCheckedContinuation { updateWaiter = $0 } }
        updates.append(state)
        transcriptionState = state
    }

    func endTranscription(_ state: TranscriptionActivityAttributes.ContentState?) async {
        endCount += 1
        if suspendEnd { await withCheckedContinuation { endWaiter = $0 } }
        activityState = .ended
        observers.forEach { $0(.ended) }
    }

    func observeState(_ handler: @escaping @MainActor (ActivityState) -> Void) -> Task<Void, Never> {
        observers.append(handler)
        return Task {}
    }
}
#endif
