import Foundation

/// Bounds the caller's wait, even if a Speech framework operation ignores task cancellation.
/// Deliberately uses unstructured tasks: a task group would await its uncooperative losing child.
/// A retired system request may still finish, but can no longer publish a result to this caller.
enum AppleSpeechDependencyWait {
    static let inventoryTimeout = Duration.seconds(2)
    static let preparationTimeout = Duration.seconds(120)

    static func run<Value: Sendable>(
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let completion = AppleSpeechDependencyCompletion<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard completion.install(continuation) else { return }
                let worker = Task {
                    guard completion.isPending else { return }
                    do {
                        try Task.checkCancellation()
                        let value = try await operation()
                        try Task.checkCancellation()
                        completion.finish(.success(value))
                    } catch { completion.finish(.failure(error)) }
                }
                let deadline = Task {
                    guard completion.isPending else { return }
                    do {
                        try Task.checkCancellation()
                        try await sleep(timeout)
                        try Task.checkCancellation()
                        completion.finish(.failure(AppleLocalModelError.modelAssetsUnavailable))
                    } catch is CancellationError {
                        // Another result or caller cancellation already won.
                    } catch { completion.finish(.failure(error)) }
                }
                completion.attach([worker, deadline])
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
        }
    }
}

/// A single winner owns continuation resumption. Completion drops task handles before cancellation;
/// late dependency replies cannot retain a completed waiter or cancel a replacement operation.
private final class AppleSpeechDependencyCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result == nil
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func attach(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        if result != nil {
            lock.unlock()
            tasks.forEach { $0.cancel() }
            return
        }
        self.tasks = tasks
        lock.unlock()
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        let tasks = self.tasks
        self.continuation = nil
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}
