import Foundation
import XCTest
@testable import SpeakCore

final class AutomationCoordinatorLifecycleTests: XCTestCase {
    func testOriginalInitializerReference_RetainsZeroArgumentArity() {
        let make: () -> AutomationRequestCoordinator = AutomationRequestCoordinator.init
        let coordinator = make()
        XCTAssertFalse(coordinator.isActive)
        let bounded = AutomationRequestCoordinator(maxInFlightRequests: 1)
        XCTAssertFalse(bounded.isActive)
    }

    func testRetries_JoinOneInFlightCommandAndReplayCompletedResult() async {
        let coordinator = AutomationRequestCoordinator(maxInFlightRequests: 1)
        let entered = expectation(description: "command entered")
        let gate = AutomationTestCompletion()
        coordinator.activate { request in
            entered.fulfill()
            await gate.wait()
            return .success(id: request.id, command: request.command, result: .init(text: "once"))
        }
        let request = AutomationRequest(id: "same", command: .stopDictation, timeout: 0.05)
        let first = Task { await coordinator.respond(to: request) }
        await fulfillment(of: [entered], timeout: 1)
        let joined = await coordinator.respond(to: request)
        XCTAssertEqual(joined.error?.code, .timedOut)
        let firstResponse = await first.value
        XCTAssertEqual(firstResponse.error?.code, .timedOut)
        let rejected = await coordinator.respond(to: .init(id: "new", command: .status))
        XCTAssertEqual(rejected.error?.code, .internalError)
        await gate.finish()
        var retry = request
        retry.timeout = 1
        let completed = await coordinator.respond(to: retry)
        XCTAssertEqual(completed.result?.text, "once")
        let replay = await coordinator.respond(to: retry)
        XCTAssertEqual(replay, completed)
        coordinator.deactivate()
    }

    func testCancelledWaiter_DoesNotWaitForCommandOrRetainAnObserver() async {
        let completion = AutomationCompletion()
        let waiter = Task {
            await AutomationDeadline.value(of: completion, within: 3_600, id: "cancel", command: .status)
        }
        waiter.cancel()
        let result = await waiter.value
        XCTAssertEqual(result.error?.code, .appUnavailable)
        completion.finish(.success(id: "cancel", command: .status, result: .init()))
    }

    func testDeactivate_CancelsOwnedCommandAndLateResultCannotPoisonRestart() async {
        let coordinator = AutomationRequestCoordinator()
        let entered = expectation(description: "old handler entered")
        let cancelled = expectation(description: "old handler cancelled")
        coordinator.activate { request in
            entered.fulfill()
            do { try await Task.sleep(for: .seconds(3_600)) } catch { cancelled.fulfill() }
            return .success(id: request.id, command: request.command, result: .init(text: "old"))
        }
        let request = AutomationRequest(id: "reused", command: .status)
        let old = Task { await coordinator.respond(to: request) }
        await fulfillment(of: [entered], timeout: 1)
        coordinator.deactivate()
        coordinator.activate { .success(id: $0.id, command: $0.command, result: .init(text: "new")) }
        await fulfillment(of: [cancelled], timeout: 1)
        let stopped = await old.value
        XCTAssertEqual(stopped.error?.code, .appUnavailable)
        let fresh = await coordinator.respond(to: request)
        XCTAssertEqual(fresh.result?.text, "new")
        coordinator.deactivate()
    }
}

private actor AutomationTestCompletion {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if finished { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish() {
        finished = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
