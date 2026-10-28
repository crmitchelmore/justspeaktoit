import Foundation
import XCTest
@testable import SpeakApp

@MainActor
final class ComparisonLocalWorkGateTests: XCTestCase {
    func testTimeoutRetainsPermitUntilIgnoredCancellationActuallyExits() async throws {
        let gate = ComparisonLocalWorkGate()
        let run = HeldComparisonLocalWork(gate: gate, modelID: "local/first", timeout: .milliseconds(250))
        addTeardownBlock { @MainActor in await run.cleanUp() }
        guard await self.completed(run.operation.started) else { return }
        guard await self.completed(run.finished) else { return }
        let outcome = await run.task.value
        XCTAssertNil(outcome)
        XCTAssertTrue(run.operation.isActive, "The fake deliberately ignores cancellation until released")

        var refusedAllocations = 0
        await self.assertRefused(gate, modelID: "local/first") { refusedAllocations += 1 }
        XCTAssertEqual(refusedAllocations, 0, "A second comparison cannot allocate another native operation")
        run.operation.finish()
        guard await self.completed(run.lifetime.exited) else { return }
        XCTAssertFalse(run.operation.isActive)
        let next = try await gate.run(modelID: "local/first") { 42 }
        XCTAssertEqual(next, 42)
        XCTAssertEqual(refusedAllocations, 0, "Refusal must not enqueue hidden work for later")
    }

    func testCallerCancellationDoesNotReleaseStillActiveLocalOperation() async throws {
        let gate = ComparisonLocalWorkGate()
        let run = HeldComparisonLocalWork(gate: gate, modelID: "local/first", timeout: .seconds(30))
        addTeardownBlock { @MainActor in await run.cleanUp() }
        guard await self.completed(run.operation.started) else { return }
        run.task.cancel()
        guard await self.completed(run.finished) else { return }
        guard case .failure(let error) = await run.task.value else {
            return XCTFail("Caller cancellation must still release the deadline waiter")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertTrue(run.operation.isActive)
        await self.assertRefused(gate, modelID: "local/first") { XCTFail("Must not allocate a second operation") }
        run.operation.finish()
        guard await self.completed(run.lifetime.exited) else { return }
        XCTAssertFalse(run.operation.isActive)
        let next = try await gate.run(modelID: "local/first") { 7 }
        XCTAssertEqual(next, 7)
    }

    func testCancellationBeforeAdmissionAllocatesNothingAndLeavesNoPermit() async throws {
        let gate = ComparisonLocalWorkGate()
        var allocations = 0
        let task = Task {
            try await gate.run(modelID: "local/first") { allocations += 1; return 1 }
        }
        task.cancel() // MainActor has not yielded, so the admission has not run.
        switch await task.result {
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("Already cancelled admission must refuse work")
        }
        XCTAssertEqual(allocations, 0)
        let result = try await gate.run(modelID: "local/first") { allocations += 1; return 2 }
        XCTAssertEqual(result, 2)
        XCTAssertEqual(allocations, 1)
    }

    func testSuccessfulAndThrowingOperationsBothReleaseTheirOwnPermit() async throws {
        let gate = ComparisonLocalWorkGate()
        let first = try await gate.run(modelID: "local/first") { "original transcript" }
        XCTAssertEqual(first, "original transcript")
        do {
            let _: Int = try await gate.run(modelID: "local/first") { throw CocoaError(.fileReadCorruptFile) }
            XCTFail("The original operation's error must propagate")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile)
        }
        let next = try await gate.run(modelID: "local/first") { "next transcript" }
        XCTAssertEqual(next, "next transcript")
    }

    func testStaleReleaseCannotClearReplacementModelsPermit() throws {
        let gate = ComparisonLocalWorkGate()
        let old = try XCTUnwrap(gate.acquire(modelID: "local/first"))
        gate.release(old)
        let replacement = try XCTUnwrap(gate.acquire(modelID: "local/first"))
        XCTAssertNotEqual(old, replacement)
        gate.release(old)
        XCTAssertNil(gate.acquire(modelID: "local/first"), "An old cleanup cannot release a later owner")
        gate.release(replacement)
        let next = try XCTUnwrap(gate.acquire(modelID: "local/first"))
        gate.release(next)
    }

    func testOtherModelsAndUngatedWorkContinueWhileTimedOutNativeWorkUnwinds() async throws {
        let gate = ComparisonLocalWorkGate()
        let run = HeldComparisonLocalWork(gate: gate, modelID: "local/first", timeout: .milliseconds(250))
        addTeardownBlock { @MainActor in await run.cleanUp() }
        guard await self.completed(run.operation.started) else { return }
        guard await self.completed(run.finished) else { return }
        XCTAssertTrue(run.operation.isActive)
        let other = await BoundedOperation.run(timeout: .seconds(1)) {
            try await gate.run(modelID: "local/other") { 99 }
        }
        guard case .success(let value) = other else { return XCTFail("Another local model must stay independent") }
        XCTAssertEqual(value, 99)
        // Cloud lanes retain their direct, ungated operation path in ComparisonFileRunner.
        let ungated = await BoundedOperation.run(timeout: .seconds(1)) { 7 }
        guard case .success(let value) = ungated else { return XCTFail("Ungated work must remain independent") }
        XCTAssertEqual(value, 7)
        XCTAssertTrue(run.operation.isActive)
    }

    private func assertRefused(
        _ gate: ComparisonLocalWorkGate,
        modelID: String,
        allocation: @escaping @MainActor () -> Void
    ) async {
        // A broken implementation that queues instead of refusing is also bounded here.
        let result = await BoundedOperation.run(timeout: .seconds(1)) {
            try await gate.run(modelID: modelID) { allocation(); return 1 }
        }
        guard case .failure(let error) = result else { return XCTFail("Expected immediate visible refusal") }
        XCTAssertEqual(error as? ComparisonLocalWorkError, .modelBusy)
        XCTAssertEqual(
            error.localizedDescription,
            "A previous comparison for this model is still active. Try again when it finishes."
        )
    }

    private func completed(_ receipt: XCTestExpectation) async -> Bool {
        let complete = await XCTWaiter.fulfillment(of: [receipt], timeout: 2) == .completed
        if !complete { XCTFail("Owned comparison did not reach bounded receipt: \(receipt.expectationDescription)") }
        return complete
    }
}

@MainActor
private final class HeldComparisonLocalWork {
    let operation: IgnoredCancellationLocalOperation
    let lifetime: ComparisonLocalOperationLifetime
    let finished: XCTestExpectation
    private let cleanupFinished: XCTestExpectation
    let task: Task<Result<Int, Error>?, Never>

    init(gate: ComparisonLocalWorkGate, modelID: String, timeout: Duration) {
        let operation = IgnoredCancellationLocalOperation()
        let lifetime = ComparisonLocalOperationLifetime()
        let finished = XCTestExpectation(description: "bounded comparison waiter finished")
        let cleanupFinished = XCTestExpectation(description: "teardown-only comparison waiter exit")
        self.operation = operation
        self.lifetime = lifetime
        self.finished = finished
        self.cleanupFinished = cleanupFinished
        self.task = Task {
            defer { finished.fulfill(); cleanupFinished.fulfill() }
            return await BoundedOperation.run(timeout: timeout) {
                lifetime.entered = true
                defer { lifetime.exited.fulfill(); lifetime.cleanupExited.fulfill() }
                return try await gate.run(modelID: modelID) { await operation.run() }
            }
        }
    }

    func cleanUp() async {
        self.operation.finish() // Release-before-arrival is safe even if the test failed before admission.
        self.task.cancel()
        guard await XCTWaiter.fulfillment(of: [self.cleanupFinished], timeout: 2) == .completed else {
            return XCTFail("Owned comparison waiter did not stop")
        }
        if self.lifetime.entered {
            guard await XCTWaiter.fulfillment(of: [self.lifetime.cleanupExited], timeout: 2) == .completed else {
                return XCTFail("Owned ignored-cancellation operation did not exit")
            }
        }
        XCTAssertFalse(self.operation.isActive)
    }
}

@MainActor
private final class ComparisonLocalOperationLifetime {
    var entered = false
    let exited = XCTestExpectation(description: "actual local operation exited and released permit")
    let cleanupExited = XCTestExpectation(description: "teardown-only actual local operation exit")
}

/// The native-work stand-in has no task cancellation handler or polling check.
@MainActor
private final class IgnoredCancellationLocalOperation {
    let started = XCTestExpectation(description: "local operation actually started")
    private(set) var isActive = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func run() async -> Int {
        self.isActive = true
        defer { self.isActive = false }
        await withCheckedContinuation { continuation in
            self.started.fulfill()
            if self.released { continuation.resume() } else { self.continuation = continuation }
        }
        return 1
    }

    func finish() {
        self.released = true
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }
}
