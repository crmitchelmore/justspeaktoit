import Foundation

struct TransportHangGuardTimeout: Error, CustomStringConvertible {
    let stage: String
    let seconds: TimeInterval
    var description: String { "Loopback \(stage) did not complete within \(seconds)s" }
}

/// Runs `operation` but returns within `seconds` even if it never completes,
/// so a stuck Network.framework callback fails the test instead of the job.
/// A timed-out operation is cancelled and left to finish on its own.
func withHangGuard<T: Sendable>(
    _ stage: String, seconds: TimeInterval = 10, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = HangGuardGate<T>()
    return try await withCheckedThrowingContinuation { continuation in
        gate.install(continuation)
        let work = Task { gate.finish(await Result { try await operation() }) }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if gate.finish(.failure(TransportHangGuardTimeout(stage: stage, seconds: seconds))) { work.cancel() }
        }
    }
}

private final class HangGuardGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let early: Result<T, Error>? = lock.withLock {
            if let pending { self.pending = nil; return pending }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    @discardableResult
    func finish(_ result: Result<T, Error>) -> Bool {
        let target: CheckedContinuation<T, Error>? = lock.withLock {
            if let continuation { self.continuation = nil; return continuation }
            if pending == nil { pending = result }
            return nil
        }
        target?.resume(with: result)
        return target != nil
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

/// Collects what the Mac would insert, so assertions can read it after the wait.
final class TranscriptInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSessionId: String?
    private var storedText: String?

    var sessionId: String? {
        self.lock.withLock { self.storedSessionId }
    }

    var text: String? {
        self.lock.withLock { self.storedText }
    }

    func record(sessionId: String, text: String) {
        self.lock.withLock {
            self.storedSessionId = sessionId
            self.storedText = text
        }
    }
}
