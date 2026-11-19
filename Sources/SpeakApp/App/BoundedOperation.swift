import Foundation

/// A cancellation-aware deadline that never waits for a non-cooperative task.
enum BoundedOperation {
    /// `onCancel` aborts owned resources once, before a timeout/cancellation is published.
    /// It must be fast and nonblocking; schedule any asynchronous native teardown inside it.
    static func run<Value: Sendable>(
        timeout: Duration,
        onCancel: @escaping @Sendable () -> Void = {},
        operation: @escaping @MainActor () async throws -> Value
    ) async -> Result<Value, any Error>? {
        let gate = OnceResumption<Result<Value, any Error>?>(onCancel: onCancel)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.arm(continuation)
                if gate.isSettled { return }
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
                    gate.resume(nil, cancelOperation: true)
                }
                gate.track(timer)
            }
        } onCancel: {
            gate.resume(.failure(CancellationError()), cancelOperation: true)
        }
    }

    private final class OnceResumption<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?
        private var settled = false
        private var published = false
        private var pending: Value?
        private var tasks: [Task<Void, Never>] = []
        private let onCancel: @Sendable () -> Void

        init(onCancel: @escaping @Sendable () -> Void) {
            self.onCancel = onCancel
        }

        var isSettled: Bool { lock.withLock { settled } }

        func arm(_ continuation: CheckedContinuation<Value, Never>) {
            let value = lock.withLock { () -> Value? in
                if published { return pending }
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

        func resume(_ value: Value, cancelOperation: Bool = false) {
            let cancelledTasks = lock.withLock { () -> [Task<Void, Never>]? in
                guard !settled else { return nil }
                settled = true
                pending = .some(value)
                let result = tasks
                tasks = []
                return result
            }
            guard let cancelledTasks else { return }
            for task in cancelledTasks { task.cancel() }
            // Abort the owned request before publishing a timeout/cancellation;
            // cancelling a Swift task alone cannot stop non-cooperative work.
            if cancelOperation { onCancel() }
            let continuation = lock.withLock {
                published = true
                let result = self.continuation
                self.continuation = nil
                return result
            }
            continuation?.resume(returning: value)
        }
    }
}
