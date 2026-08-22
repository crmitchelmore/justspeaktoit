import Foundation

/// Runs an operation with a deadline the caller can rely on.
///
/// A late completion is discarded rather than awaited, so an operation that
/// wedges (a Core ML decode, a socket send) cannot hold a stop path open
/// indefinitely. The operation itself keeps running to completion in its own
/// task; only the wait is bounded.
enum BoundedOperation {
    /// Returns the operation's outcome, or nil if `timeout` elapsed first.
    static func run<Value: Sendable>(
        timeout: Duration,
        operation: @escaping @MainActor () async throws -> Value
    ) async -> Result<Value, any Error>? {
        let resumption = OnceResumption<Result<Value, any Error>?>()
        var timeoutTask: Task<Void, Never>?
        let outcome = await withCheckedContinuation { continuation in
            resumption.arm(continuation)
            Task { @MainActor in
                do {
                    resumption.resume(.success(try await operation()))
                } catch {
                    resumption.resume(.failure(error))
                }
            }
            timeoutTask = Task {
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                resumption.resume(nil)
            }
        }
        timeoutTask?.cancel()
        return outcome
    }

    /// Resumes a continuation exactly once from whichever racing task
    /// finishes first.
    private final class OnceResumption<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?

        func arm(_ continuation: CheckedContinuation<Value, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func resume(_ value: Value) {
            let continuation = lock.withLock { () -> CheckedContinuation<Value, Never>? in
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: value)
        }
    }
}
