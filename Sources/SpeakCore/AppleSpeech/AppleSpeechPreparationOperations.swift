import Foundation

/// Shares only explicitly requested, in-flight preparation. Each caller owns one subscription.
@MainActor
final class AppleSpeechPreparationOperations {
    typealias Configuration = AppleSpeechModelPreparation.Configuration
    typealias Operation = AppleSpeechModelPreparation.Operation
    typealias Resolve = @MainActor @Sendable (Configuration) async throws -> Operation
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct Caller {
        let cancellation: AppleSpeechPreparationCancellation
        let continuation: CheckedContinuation<Void, Error>
        let onPreparing: @MainActor @Sendable () -> Void
    }

    private struct Pending {
        let id: UUID
        let task: Task<Void, Never>
        var callers: [UUID: Caller]
        var isPreparing = false
    }

    private var pending: [Configuration: Pending] = [:]
    private let resolve: Resolve
    private let sleep: Sleep

    init(sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, resolve: @escaping Resolve) {
        self.resolve = resolve
        self.sleep = sleep
    }

    func prepare(
        _ configuration: Configuration,
        onPreparing: @escaping @MainActor @Sendable () -> Void
    ) async throws -> Configuration {
        let resolve = self.resolve
        let operation = try await AppleSpeechDependencyWait.run(
            timeout: AppleSpeechDependencyWait.inventoryTimeout, sleep: sleep
        ) { try await resolve(configuration) }
        try Task.checkCancellation()
        let key = operation.configuration
        let callerID = UUID()
        let cancellation = AppleSpeechPreparationCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                // Cancellation is marked synchronously, even before its MainActor cleanup gets a turn.
                let cancelled = pending[key]?.callers.filter { $0.value.cancellation.isCancelled }.map(\.key) ?? []
                for id in cancelled { withdraw(id, from: key) }
                let caller = Caller(cancellation: cancellation, continuation: continuation, onPreparing: onPreparing)
                if var existing = pending[key] {
                    existing.callers[callerID] = caller
                    pending[key] = existing
                    if existing.isPreparing { onPreparing() }
                } else {
                    let id = UUID()
                    let task = start(operation, id: id)
                    pending[key] = Pending(id: id, task: task, callers: [callerID: caller])
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor in self.withdraw(callerID, from: key) }
        }
        try Task.checkCancellation()
        return key
    }

    private func start(_ operation: Operation, id: UUID) -> Task<Void, Never> {
        let sleep = self.sleep
        let key = operation.configuration
        return Task { [weak self] in
            let result: Result<Void, Error>
            do {
                try await AppleSpeechDependencyWait.run(
                    timeout: AppleSpeechDependencyWait.preparationTimeout, sleep: sleep
                ) { [weak self] in
                    try await operation.run { [weak self] in self?.preparing(key, id: id) }
                }
                result = .success(())
            } catch { result = .failure(error) }
            self?.complete(key, id: id, result: result)
        }
    }

    private func preparing(_ key: Configuration, id: UUID) {
        guard var entry = pending[key], entry.id == id else { return }
        entry.isPreparing = true
        pending[key] = entry
        for caller in entry.callers.values { caller.onPreparing() }
    }

    private func complete(_ key: Configuration, id: UUID, result: Result<Void, Error>) {
        guard let entry = pending[key], entry.id == id else { return }
        pending[key] = nil
        for caller in entry.callers.values { caller.continuation.resume(with: result) }
    }

    private func withdraw(_ callerID: UUID, from key: Configuration) {
        guard var entry = pending[key], let caller = entry.callers.removeValue(forKey: callerID) else { return }
        if entry.callers.isEmpty {
            // Retire immediately, independently of whether the framework cooperates with cancellation.
            pending[key] = nil
            entry.task.cancel()
        } else {
            pending[key] = entry
        }
        caller.continuation.resume(throwing: CancellationError())
    }
}

private final class AppleSpeechPreparationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
