import Foundation

/// A cancellation-aware deadline that never waits for a non-cooperative task.
enum BoundedOperation {
    static func run<Value: Sendable>(
        timeout: Duration,
        operation: @escaping @MainActor () async throws -> Value
    ) async -> Result<Value, any Error>? {
        let gate = OnceResumption<Result<Value, any Error>?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.arm(continuation)
                let work = Task { @MainActor in
                    do {
                        try Task.checkCancellation()
                        gate.resume(.success(try await operation()))
                    } catch {
                        gate.resume(.failure(error))
                    }
                }
                gate.track(work)
                let timer = Task {
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    gate.resume(nil)
                }
                gate.track(timer)
            }
        } onCancel: {
            gate.resume(.failure(CancellationError()))
        }
    }

    private final class OnceResumption<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?
        private var settled = false
        private var pending: Value?
        private var tasks: [Task<Void, Never>] = []

        func arm(_ continuation: CheckedContinuation<Value, Never>) {
            let value = lock.withLock { () -> Value? in
                if settled { return pending }
                self.continuation = continuation
                return nil
            }
            if let value { continuation.resume(returning: value) }
        }

        func track(_ task: Task<Void, Never>) {
            let cancel = lock.withLock {
                if settled { return true }
                tasks.append(task)
                return false
            }
            if cancel { task.cancel() }
        }

        func resume(_ value: Value) {
            let state = lock.withLock { () -> (CheckedContinuation<Value, Never>?, [Task<Void, Never>])? in
                guard !settled else { return nil }
                settled = true
                pending = .some(value)
                let result = (continuation, tasks)
                continuation = nil
                tasks = []
                return result
            }
            guard let (continuation, tasks) = state else { return }
            continuation?.resume(returning: value)
            for task in tasks { task.cancel() }
        }
    }
}
