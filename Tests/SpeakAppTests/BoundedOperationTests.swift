import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakApp

@MainActor
final class BoundedOperationTests: XCTestCase {
    func testTimeoutDoesNotDrainNonCooperativeOperation() async {
        var continuation: CheckedContinuation<Int, Never>?
        let result = await BoundedOperation.run(timeout: .milliseconds(50)) {
            await withCheckedContinuation { continuation = $0 }
        }
        XCTAssertNil(result)
        // Resume the deliberately non-cooperative work so the test leaks no task.
        continuation?.resume(returning: 42)
    }

    func testCancellationReleasesWaiterBeforeDeadline() async {
        let task = Task {
            await BoundedOperation.run(timeout: .seconds(30)) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        task.cancel()
        let result = await task.value
        guard case .failure(let error) = result else { return XCTFail("Expected cancellation") }
        XCTAssertTrue(error is CancellationError)
    }

    func testTimeoutCancelsOwnedNonCooperativeRequestBeforeReturning() async {
        let provider = NonCooperativeComparisonRequest()
        let unrelated = NonCooperativeComparisonRequest()
        let otherRecording = Task { try await unrelated.transcribe() }
        let result = await BoundedOperation.run(
            timeout: .milliseconds(50), onCancel: { provider.cancel() },
            operation: { try await provider.transcribe() }
        )
        XCTAssertNil(result)
        XCTAssertFalse(provider.isActive)
        XCTAssertEqual(provider.cancelCount, 1)
        XCTAssertTrue(unrelated.isActive, "A deadline must not stop another recording's request")
        unrelated.cancel()
        _ = try? await otherRecording.value
    }

    func testCallerCancellationAbortsOwnedRequestExactlyOnce() async {
        let started = expectation(description: "Owned request started")
        let provider = NonCooperativeComparisonRequest(onStart: { started.fulfill() })
        let task = Task {
            await BoundedOperation.run(
                timeout: .seconds(30), onCancel: { provider.cancel() },
                operation: { try await provider.transcribe() }
            )
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        task.cancel()
        let result = await task.value
        guard case .failure(let error) = result else { return XCTFail("Expected cancellation") }
        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(provider.isActive)
        XCTAssertEqual(provider.cancelCount, 1)
    }

    func testSuccessDoesNotAbortOwnedRequest() async {
        let provider = NonCooperativeComparisonRequest()
        let result = await BoundedOperation.run(
            timeout: .seconds(30), onCancel: { provider.cancel() }, operation: { 42 }
        )
        guard case .success(let value) = result else { return XCTFail("Expected successful result") }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(provider.cancelCount, 0)
    }

    func testAlreadyCancelledWaiterAbortsHandleBeforeReturning() async {
        let provider = NonCooperativeComparisonRequest()
        let task = Task {
            await BoundedOperation.run(
                timeout: .seconds(30), onCancel: { provider.cancel() },
                operation: { try await provider.transcribe() }
            )
        }
        task.cancel()
        _ = await task.value
        XCTAssertFalse(provider.isActive)
        XCTAssertEqual(provider.cancelCount, 1)
    }

    func testOwnedSessionAbortStopsUncooperativeProviderNetworkOnly() async {
        StubURLProtocol.handler = { _ in .hang }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let owned = URLSession(configuration: configuration)
        let unrelated = URLSession(configuration: configuration)
        defer {
            owned.invalidateAndCancel()
            unrelated.invalidateAndCancel()
            StubURLProtocol.reset()
        }
        let unrelatedStarted = expectation(description: "Other recording request started")
        StubURLProtocol.onStartLoading = { unrelatedStarted.fulfill() }
        let url = URL(string: "https://comparison.invalid/transcribe")!
        let recording = Task { try await Self.nonCooperativeData(session: unrelated, url: url) }
        await fulfillment(of: [unrelatedStarted], timeout: 1)
        StubURLProtocol.onStartLoading = nil
        let stopped = expectation(description: "Owned native request stopped")
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        let result = await BoundedOperation.run(
            timeout: .seconds(1), onCancel: { owned.invalidateAndCancel() },
            operation: { try await Self.nonCooperativeData(session: owned, url: url) }
        )
        XCTAssertNil(result)
        await fulfillment(of: [stopped], timeout: 1)
        let ownedCount = await Self.activeRequests(in: owned)
        let unrelatedCount = await Self.activeRequests(in: unrelated)
        XCTAssertEqual(ownedCount, 0)
        XCTAssertEqual(unrelatedCount, 1)
        StubURLProtocol.onStopLoading = nil
        unrelated.invalidateAndCancel()
        _ = try? await recording.value
    }

    private static func activeRequests(in session: URLSession) async -> Int {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks.filter { $0.state == .running }.count)
            }
        }
    }

    /// Completion-handler transport deliberately has no Swift cancellation handler.
    private static func nonCooperativeData(session: URLSession, url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: url) { data, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }.resume()
        }
    }
}

/// Deliberately ignores Swift task cancellation; only its owned request handle can stop it.
private final class NonCooperativeComparisonRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let onStart: @Sendable () -> Void
    private var continuation: CheckedContinuation<Int, Error>?
    private var cancelled = false
    private var cancellations = 0

    init(onStart: @escaping @Sendable () -> Void = {}) { self.onStart = onStart }

    var isActive: Bool { lock.withLock { continuation != nil } }
    var cancelCount: Int { lock.withLock { cancellations } }

    func transcribe() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let cancelled = lock.withLock {
                if self.cancelled { return true }
                self.continuation = continuation
                return false
            }
            if cancelled { continuation.resume(throwing: CancellationError()) }
            onStart()
        }
    }

    func cancel() {
        let continuation = lock.withLock {
            cancellations += 1
            cancelled = true
            let pending = self.continuation
            self.continuation = nil
            return pending
        }
        continuation?.resume(throwing: CancellationError())
    }
}
