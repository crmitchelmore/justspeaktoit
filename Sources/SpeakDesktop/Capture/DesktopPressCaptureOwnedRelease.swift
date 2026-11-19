import Foundation

/// Owns one run's release result, not the lease-global current run or its latest failure.
/// Startup/record/shutdown owners must retain this ticket and explicitly release it.
package actor DesktopPressCaptureOwnedRelease {
    private enum Outcome {
        case pending
        case finished(DesktopPressCaptureError?)
    }

    package nonisolated let token: DesktopPressCaptureToken
    package nonisolated let identity: DesktopPressCaptureIdentity
    private let lease: DesktopPressCaptureLease
    private let initialAttempt: DesktopPressCaptureReleaseAttempt
    private var operation: Task<DesktopPressCaptureError?, Never>?
    private var generation: UInt64 = 0
    private var retrying = false
    private var outcome = Outcome.pending

    init(lease: DesktopPressCaptureLease, attempt: DesktopPressCaptureReleaseAttempt) {
        self.lease = lease
        self.initialAttempt = attempt
        self.token = attempt.token
        self.identity = attempt.identity
    }

    package func release() async throws {
        if operation == nil {
            operation = Task { [lease, token, initialAttempt] in
                await lease.cancel(token)
                return await initialAttempt.value()
            }
        }
        if let operation { try await join(operation, generation: generation) }
    }

    package func retryRelease() async throws {
        guard let previous = operation else { throw DesktopPressCaptureError.invalidPhase }
        if retrying { try await join(previous, generation: generation); return }
        guard case let .finished(error) = outcome, error != nil else {
            throw DesktopPressCaptureError.invalidPhase
        }
        generation &+= 1
        let attemptGeneration = generation
        retrying = true
        outcome = .pending
        let retry = Task { [lease, token, identity] in
            switch await lease.retryOwnedRelease(token, identity: identity) {
            case let .success(attempt): return await attempt.value()
            case let .failure(error): return error
            }
        }
        operation = retry
        defer { if generation == attemptGeneration { retrying = false } }
        try await join(retry, generation: attemptGeneration)
    }

    private func join(_ operation: Task<DesktopPressCaptureError?, Never>, generation observed: UInt64) async throws {
        let error = await operation.value
        if generation == observed { outcome = .finished(error) }
        if let error { throw error }
    }
}

/// Exactly one owned task awaits each attempt; concurrent callers join that task.
actor DesktopPressCaptureReleaseAttempt {
    nonisolated let token: DesktopPressCaptureToken
    nonisolated let identity: DesktopPressCaptureIdentity
    private var finished = false
    private var error: DesktopPressCaptureError?
    private var waiter: CheckedContinuation<DesktopPressCaptureError?, Never>?

    init(token: DesktopPressCaptureToken, identity: DesktopPressCaptureIdentity) {
        self.token = token
        self.identity = identity
    }

    func value() async -> DesktopPressCaptureError? {
        if finished { return error }
        precondition(waiter == nil)
        return await withCheckedContinuation { waiter = $0 }
    }

    func complete(error: DesktopPressCaptureError?) {
        guard !finished else { return }
        finished = true
        self.error = error
        waiter?.resume(returning: error)
        waiter = nil
    }
}
