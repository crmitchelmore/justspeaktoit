import Foundation

/// A deadline that returns even if a native/provider operation ignores cancellation.
enum DesktopComparisonDeadline {
    static func run<Value: Sendable>(
        timeout: Duration, operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let gate = Gate<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.arm(continuation)
                gate.track(Task {
                    do {
                        try Task.checkCancellation()
                        gate.settle(.success(try await operation()))
                    } catch { gate.settle(.failure(error)) }
                })
                gate.track(Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    gate.settle(.failure(DesktopComparisonError.message("The model exceeded its time limit.")))
                })
            }
        } onCancel: { gate.settle(.failure(CancellationError())) }
    }

    private final class Gate<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Value, Error>?
        private var continuation: CheckedContinuation<Value, Error>?
        private var tasks: [Task<Void, Never>] = []

        func arm(_ continuation: CheckedContinuation<Value, Error>) {
            let result: Result<Value, Error>? = lock.withLock {
                if let result = self.result { return result }
                self.continuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }

        func track(_ task: Task<Void, Never>) {
            let cancel = lock.withLock {
                if result != nil { return true }
                tasks.append(task)
                return false
            }
            if cancel { task.cancel() }
        }

        func settle(_ result: Result<Value, Error>) {
            let settled = lock.withLock { () -> (CheckedContinuation<Value, Error>?, [Task<Void, Never>])? in
                guard self.result == nil else { return nil }
                self.result = result
                defer { continuation = nil; tasks = [] }
                return (continuation, tasks)
            }
            guard let (continuation, tasks) = settled else { return }
            continuation?.resume(with: result)
            tasks.forEach { $0.cancel() }
        }
    }
}

public enum DesktopComparisonError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}
