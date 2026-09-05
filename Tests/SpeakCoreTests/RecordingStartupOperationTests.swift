import Foundation
import XCTest
@testable import SpeakCore

@MainActor
final class RecordingStartupOperationTests: XCTestCase {
    func testRetiringRun_interruptsPermissionWaitAndSettlesWithoutSystemReply() async throws {
        let lifecycle = RecordingLifecycleCoordinator()
        let startup = RecordingStartupOperation()
        let runID = try XCTUnwrap(lifecycle.beginStart())
        let entered = expectation(description: "provider waiting for permission")
        let stopped = expectation(description: "stop returned")
        var reply: (@Sendable (Bool) -> Void)?
        var resourceOwned = false
        var activated = false
        var cancelCalls = 0
        XCTAssertTrue(lifecycle.installStartCancellation(for: runID) {
            cancelCalls += 1
            startup.cancel()
        })
        let start = Task { @MainActor in
            do {
                try await startup.run({
                    resourceOwned = true
                    _ = await CancellablePermissionRequest.request { callback in
                        reply = callback
                        entered.fulfill()
                    }
                    try Task.checkCancellation()
                    activated = true
                }, onFailure: {
                    XCTAssertTrue(startup.isStarting, "cleanup must retain startup ownership")
                    resourceOwned = false
                })
                XCTFail("retired startup activated")
            } catch {
                XCTAssertTrue(error is CancellationError)
                startup.cancel() // the manager's catch can cancel again safely
                lifecycle.finishStartUnwind()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        lifecycle.retireStartRun()
        lifecycle.retireStartRun()
        let stop = Task { @MainActor in
            await lifecycle.awaitStartSettled()
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertFalse(activated)
        XCTAssertFalse(resourceOwned)
        XCTAssertFalse(startup.isStarting)
        XCTAssertEqual(cancelCalls, 1)
        XCTAssertEqual(lifecycle.state, .idle)
        // The system prompt may complete much later, or call back twice.
        reply?(true)
        reply?(false)
        await start.value
        await stop.value
        XCTAssertFalse(activated)
    }

    func testCancellation_waitsForAsynchronousCleanupBeforeReleasingOwnership() async {
        let startup = RecordingStartupOperation()
        let entered = expectation(description: "start suspended")
        let cleanupEntered = expectation(description: "cleanup suspended")
        let finished = expectation(description: "start settled")
        var finishCleanup: CheckedContinuation<Void, Never>?
        let start = Task { @MainActor in
            do {
                try await startup.run({
                    _ = await CancellablePermissionRequest.request { _ in entered.fulfill() }
                    try Task.checkCancellation()
                }, onFailure: {
                    await withCheckedContinuation { continuation in
                        finishCleanup = continuation
                        cleanupEntered.fulfill()
                    }
                })
                XCTFail("expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
            finished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        startup.cancel()
        await fulfillment(of: [cleanupEntered], timeout: 2)
        XCTAssertTrue(startup.isStarting)
        var replacementRan = false
        try? await startup.run { replacementRan = true }
        XCTAssertFalse(replacementRan, "a replacement must not overlap analyzer teardown")
        finishCleanup?.resume()
        finishCleanup = nil
        await fulfillment(of: [finished], timeout: 2)
        await start.value
        XCTAssertFalse(startup.isStarting)
        try? await startup.run { replacementRan = true }
        XCTAssertTrue(replacementRan)
    }

    func testCancellingCaller_forwardsToOwnedProviderTask() async {
        let startup = RecordingStartupOperation()
        let entered = expectation(description: "permission requested")
        let finished = expectation(description: "cancel propagated")
        let start = Task { @MainActor in
            do {
                try await startup.run {
                    _ = await CancellablePermissionRequest.request { _ in entered.fulfill() }
                    try Task.checkCancellation()
                }
                XCTFail("expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
            finished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        start.cancel()
        await fulfillment(of: [finished], timeout: 2)
        await start.value
        XCTAssertFalse(startup.isStarting)
    }

    func testPermissionCancellationBeforeInstallation_doesNotStartSystemPrompt() async {
        var requested = false
        let request = Task { @MainActor in
            await CancellablePermissionRequest.request { callback in
                requested = true
                callback(true)
            }
        }
        request.cancel() // main actor has not yielded to the new task yet
        let granted = await request.value
        XCTAssertFalse(granted)
        XCTAssertFalse(requested)
    }

    func testPermissionSynchronousDuplicateReply_usesFirstResult() async {
        let granted = await CancellablePermissionRequest.request { callback in
            callback(true)
            callback(false)
        }
        XCTAssertTrue(granted)
    }

    func testLateCancellationRegistration_cannotOwnReplacementRun() throws {
        let lifecycle = RecordingLifecycleCoordinator()
        let oldRun = try XCTUnwrap(lifecycle.beginStart())
        lifecycle.retireStartRun()
        lifecycle.finishStartUnwind()
        let newRun = try XCTUnwrap(lifecycle.beginStart())
        var oldCancelled = false
        var newCancelled = false
        XCTAssertTrue(lifecycle.installStartCancellation(for: newRun) { newCancelled = true })
        XCTAssertFalse(lifecycle.installStartCancellation(for: oldRun) { oldCancelled = true })
        XCTAssertTrue(oldCancelled)
        XCTAssertFalse(newCancelled)
        lifecycle.retireStartRun()
        XCTAssertTrue(newCancelled)
    }
}
