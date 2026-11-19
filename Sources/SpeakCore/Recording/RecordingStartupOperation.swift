import Foundation

/// Owns a provider startup task until it settles. Cancellation is forwarded to
/// suspension points without releasing startup ownership early: a replacement
/// cannot overlap the old operation's resource cleanup.
@MainActor
public final class RecordingStartupOperation {
    private var task: Task<Void, Error>?

    public init() {}

    public var isStarting: Bool { task != nil }

    public func run(
        _ operation: @escaping @MainActor () async throws -> Void,
        onFailure: @escaping @MainActor () async -> Void = {}
    ) async throws {
        guard task == nil else { return }
        try Task.checkCancellation()
        let pending = Task { @MainActor in
            do {
                try Task.checkCancellation()
                try await operation()
                try Task.checkCancellation()
            } catch {
                // Keep ownership until cleanup finishes. Clearing the task
                // before the caller's catch could let a new start overlap it.
                await onFailure()
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw error
            }
        }
        task = pending
        defer { task = nil }
        try await withTaskCancellationHandler {
            try await pending.value
        } onCancel: {
            pending.cancel()
        }
    }

    /// Idempotent. The task remains owned until its caller observes completion.
    public func cancel() {
        task?.cancel()
    }
}
