import Foundation

/// The sync work a desktop host starts — its timer, passes after History
/// changes, dialog actions and sign-in — owned until each piece ends.
///
/// Shutdown calls `stop()`: from then on nothing new starts, everything that
/// runs is cancelled, and `ifRunning` no longer lets a result reach the
/// window. `drain(_:until:)` then waits for the cancelled work within a bound,
/// because a request that cannot be abandoned must not hold the window's
/// shutdown open; whatever is still running afterwards can only end.
public final class DesktopCloudSyncWork: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var running: [UUID: Task<Void, Never>] = [:]

    public init() {}

    /// How many pieces of work have not ended yet.
    public var runningCount: Int { lock.withLock { running.count } }

    /// Whether shutdown has begun.
    public var isStopped: Bool { lock.withLock { stopped } }

    /// Starts `operation` as owned work, or returns `nil` once stopped.
    @discardableResult
    public func start(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        lock.withLock {
            guard !stopped else { return nil }
            let id = UUID()
            let task = Task { [weak self] in
                await operation()
                self?.finish(id)
            }
            running[id] = task
            return task
        }
    }

    /// Runs `action` unless stopped, and `stop()` cannot return while it runs.
    /// It is for handing a result to the window, so keep it short and
    /// non-blocking, and never start or stop work from it.
    @discardableResult
    public func ifRunning<Value>(_ action: () throws -> Value) rethrows -> Value? {
        try lock.withLock {
            guard !stopped else { return nil }
            return try action()
        }
    }

    /// Refuses new work and cancels everything running, which it returns.
    public func stop() -> [Task<Void, Never>] {
        let tasks = lock.withLock { () -> [Task<Void, Never>] in
            stopped = true
            defer { running.removeAll() }
            return Array(running.values)
        }
        tasks.forEach { $0.cancel() }
        return tasks
    }

    /// Waits until every task has ended or `deadline` has returned, whichever
    /// comes first.
    public static func drain(
        _ tasks: [Task<Void, Never>],
        until deadline: @escaping @Sendable () async -> Void
    ) async {
        guard !tasks.isEmpty else { return }
        let (ended, signal) = AsyncStream<Void>.makeStream()
        let waiter = Task {
            for task in tasks {
                await task.value
            }
            signal.yield()
        }
        let timer = Task {
            await deadline()
            signal.yield()
        }
        var iterator = ended.makeAsyncIterator()
        _ = await iterator.next()
        signal.finish()
        timer.cancel()
        waiter.cancel()
    }

    private func finish(_ id: UUID) {
        lock.withLock { _ = running.removeValue(forKey: id) }
    }
}
