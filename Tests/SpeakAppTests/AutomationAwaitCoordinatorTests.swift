#if os(macOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

@MainActor
final class AutomationAwaitCoordinatorTests: XCTestCase {
    private func request(_ id: String = "await", capture: UUID = UUID(), timeout: Double = 30) -> AutomationRequest {
        AutomationRequest(id: id, command: .awaitTranscript, timeout: timeout, captureID: capture.uuidString)
    }

    func testNormalizedRetry_JoinsAndReplaysFrozenResultButChangedArgumentsFail() async {
        let gate = AwaitCoordinatorGate()
        let coordinator = AutomationAwaitCoordinator()
        coordinator.activate { await gate.answer($0) }
        let request = self.request()
        let first = Task { await coordinator.respond(to: request) }
        guard await self.waitForCalls(1, gate: gate, coordinator: coordinator) else { return }
        var normalized = request
        normalized.captureID = request.captureID?.lowercased()
        let second = Task { await coordinator.respond(to: normalized) }
        await Task.yield()
        var changed = request
        changed.timeout = 31
        let rejected = await coordinator.respond(to: changed)
        XCTAssertEqual(rejected.error?.code, .invalidArgument)
        gate.finishAll("frozen")
        let result = await first.value
        let joined = await second.value
        XCTAssertEqual(result, joined)
        let cached = await coordinator.respond(to: request)
        XCTAssertEqual(cached, result)
        XCTAssertEqual(gate.calls, 1)
        coordinator.deactivate()
    }

    func testCompletionProcessedAtDeadline_LosesEvenWhenTimerHasNotRun() async {
        let initial = ContinuousClock().now
        var now = initial
        let gate = AwaitCoordinatorGate()
        let coordinator = AutomationAwaitCoordinator(now: { now })
        coordinator.activate { await gate.answer($0) }
        let request = self.request(timeout: 20)
        let pending = Task { await coordinator.respond(to: request) }
        guard await self.waitForCalls(1, gate: gate, coordinator: coordinator) else { return }
        now = initial.advanced(by: .seconds(20))
        gate.finishAll("must not escape")
        let result = await pending.value
        XCTAssertEqual(result.error?.code, .timedOut)
        XCTAssertNil(result.result)
        coordinator.deactivate()
    }

    func testDeadline_CancelsUnderlyingAndCachesTerminalWithoutExtendingOnRetry() async {
        let gate = AwaitCoordinatorGate()
        let coordinator = AutomationAwaitCoordinator()
        coordinator.activate { await gate.answer($0) }
        let request = self.request(timeout: 0.05)
        let first = Task { await coordinator.respond(to: request) }
        guard await self.waitForCalls(1, gate: gate, coordinator: coordinator) else { return }
        let second = Task { await coordinator.respond(to: request) }
        let result = await first.value
        XCTAssertEqual(result.error?.code, .timedOut)
        let joined = await second.value
        XCTAssertEqual(joined, result)
        gate.finishAll("late ignored")
        await Task.yield()
        let replay = await coordinator.respond(to: request)
        XCTAssertEqual(replay, result)
        XCTAssertEqual(gate.calls, 1)
        coordinator.deactivate()
    }

    func testOneDisconnect_DoesNotCancelSurvivor_LastDisconnectIsTerminal() async {
        let gate = AwaitCoordinatorGate()
        let coordinator = AutomationAwaitCoordinator()
        coordinator.activate { await gate.answer($0) }
        let request = self.request()
        let first = Task { await coordinator.respond(to: request) }
        guard await self.waitForCalls(1, gate: gate, coordinator: coordinator) else { return }
        let subscribed = expectation(description: "two registered subscribers")
        var registered = false
        coordinator.didChangeSubscribers = { _, count in
            if count == 2 { registered = true; subscribed.fulfill() }
        }
        let survivor = Task { await coordinator.respond(to: request) }
        await fulfillment(of: [subscribed], timeout: 2)
        guard registered else { coordinator.deactivate(); gate.finishAll("cleanup"); return }
        coordinator.didChangeSubscribers = nil
        first.cancel()
        let disconnected = await first.value
        XCTAssertEqual(disconnected.error?.code, .appUnavailable)
        gate.finishAll("survivor")
        let result = await survivor.value
        XCTAssertEqual(result.result?.text, "survivor")
        let another = self.request("another")
        let last = Task { await coordinator.respond(to: another) }
        guard await self.waitForCalls(2, gate: gate, coordinator: coordinator) else { return }
        last.cancel()
        _ = await last.value
        let replay = await coordinator.respond(to: another)
        XCTAssertEqual(replay.error?.code, .appUnavailable)
        XCTAssertEqual(gate.calls, 2)
        gate.finishAll("ignored")
        coordinator.deactivate()
    }

    func testCancellationBeforeSubscription_DoesNotRetainUnderlyingWait() async {
        let coordinator = AutomationAwaitCoordinator()
        let gate = AwaitCoordinatorGate()
        coordinator.activate { await gate.answer($0) }
        let request = self.request()
        let pending = Task { await coordinator.respond(to: request) }
        pending.cancel()
        let result = await pending.value
        XCTAssertEqual(result.error?.code, .appUnavailable)
        let replay = await coordinator.respond(to: request)
        XCTAssertEqual(replay.error?.code, .appUnavailable)
        gate.finishAll("ignored")
        coordinator.deactivate()
    }

    func testOffOn_ResetsEpochAndOldCompletionCannotSettleNewSameID() async {
        let oldGate = AwaitCoordinatorGate()
        let newGate = AwaitCoordinatorGate()
        let coordinator = AutomationAwaitCoordinator()
        let request = self.request()
        coordinator.activate { await oldGate.answer($0) }
        let old = Task { await coordinator.respond(to: request) }
        guard await self.waitForCalls(1, gate: oldGate, coordinator: coordinator) else { return }
        coordinator.deactivate()
        coordinator.activate { await newGate.answer($0) }
        let fresh = Task { await coordinator.respond(to: request) }
        guard await self.waitForCalls(1, gate: newGate, coordinator: coordinator) else { return }
        oldGate.finishAll("old")
        newGate.finishAll("new")
        let stopped = await old.value
        let current = await fresh.value
        XCTAssertEqual(stopped.error?.code, .appUnavailable)
        XCTAssertEqual(current.result?.text, "new")
        let replay = await coordinator.respond(to: request)
        XCTAssertEqual(replay.result?.text, "new")
        coordinator.deactivate()
    }

    private func waitForCalls(_ count: Int, gate: AwaitCoordinatorGate,
                              coordinator: AutomationAwaitCoordinator) async -> Bool {
        guard gate.calls < count else { return true }
        let entered = expectation(description: "underlying handlers entered")
        gate.didEnter = { if gate.calls >= count { entered.fulfill() } }
        await fulfillment(of: [entered], timeout: 2)
        gate.didEnter = nil
        guard gate.calls >= count else {
            coordinator.deactivate()
            gate.finishAll("cleanup")
            return false
        }
        return true
    }

    func testSixteenUnderlyingWaitCap_RejectsNewAndReleasesOnShutdown() async {
        let gate = AwaitCoordinatorGate()
        let coordinator = AutomationAwaitCoordinator()
        coordinator.activate { await gate.answer($0) }
        let tasks = (0..<16).map { index in Task { await coordinator.respond(to: self.request("cap-\(index)")) } }
        guard await self.waitForCalls(16, gate: gate, coordinator: coordinator) else { return }
        let rejected = await coordinator.respond(to: self.request("overflow"))
        XCTAssertEqual(rejected.error?.code, .internalError)
        coordinator.deactivate()
        for task in tasks {
            let response = await task.value
            XCTAssertEqual(response.error?.code, .appUnavailable)
        }
        gate.finishAll("late")
        coordinator.activate { .success(id: $0.id, command: $0.command, result: .init(text: "new")) }
        let admitted = await coordinator.respond(to: self.request("overflow"))
        XCTAssertEqual(admitted.result?.text, "new")
        coordinator.deactivate()
    }

    func testUnicodeWireIDs_KeepIndependentWaitsCancellationAndTerminalReplay() async {
        let gate = AwaitCoordinatorGate()
        let coordinator = AutomationAwaitCoordinator()
        coordinator.activate { await gate.answer($0) }
        let firstRequest = self.request("é")
        let secondRequest = self.request("e\u{0301}")
        let firstDone = expectation(description: "first Unicode owner disconnected")
        let secondDone = expectation(description: "other Unicode owner survived")
        var firstResponse: AutomationResponse?
        var secondResponse: AutomationResponse?
        let first = Task { firstResponse = await coordinator.respond(to: firstRequest); firstDone.fulfill() }
        let second = Task { secondResponse = await coordinator.respond(to: secondRequest); secondDone.fulfill() }
        defer { first.cancel(); second.cancel(); coordinator.deactivate(); gate.finishAll("cleanup") }
        guard await self.waitForCalls(2, gate: gate, coordinator: coordinator) else { return }
        first.cancel()
        guard await XCTWaiter.fulfillment(of: [firstDone], timeout: 2) == .completed else {
            return XCTFail("First Unicode owner did not disconnect")
        }
        XCTAssertEqual(firstResponse?.error?.code, .appUnavailable)
        XCTAssertEqual(firstResponse.map { Data($0.id.utf8) }, Data(firstRequest.id.utf8))
        gate.finishAll("survivor")
        guard await XCTWaiter.fulfillment(of: [secondDone], timeout: 2) == .completed else {
            return XCTFail("Other Unicode owner did not settle")
        }
        XCTAssertEqual(secondResponse?.result?.text, "survivor")
        XCTAssertEqual(secondResponse.map { Data($0.id.utf8) }, Data(secondRequest.id.utf8))
        let replayed = expectation(description: "each UTF-8 identity replays its own terminal result")
        let replay = Task {
            let firstCached = await coordinator.respond(to: firstRequest)
            let secondCached = await coordinator.respond(to: secondRequest)
            XCTAssertEqual(firstCached.error?.code, .appUnavailable)
            XCTAssertEqual(secondCached.result?.text, "survivor")
            replayed.fulfill()
        }
        defer { replay.cancel() }
        guard await XCTWaiter.fulfillment(of: [replayed], timeout: 2) == .completed else {
            return XCTFail("Unicode terminal replay did not settle")
        }
        XCTAssertEqual(gate.calls, 2)
    }
}

@MainActor
private final class AwaitCoordinatorGate {
    private(set) var calls = 0
    private var pending: [(AutomationRequest, CheckedContinuation<AutomationResponse, Never>)] = []
    var didEnter: (() -> Void)?

    func answer(_ request: AutomationRequest) async -> AutomationResponse {
        self.calls += 1
        return await withCheckedContinuation { continuation in
            self.pending.append((request, continuation))
            self.didEnter?()
        }
    }

    func finishAll(_ text: String) {
        let pending = self.pending
        self.pending.removeAll()
        for (request, continuation) in pending {
            continuation.resume(returning: .success(id: request.id, command: request.command,
                result: .init(text: text)))
        }
    }
}
#endif
