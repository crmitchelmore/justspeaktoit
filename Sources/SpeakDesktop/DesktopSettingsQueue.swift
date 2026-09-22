import Foundation

/// Runs a desktop host's settings work one operation at a time, in submission
/// order. Hosts submit from their UI thread, so that order is the user's.
///
/// Waiting for earlier work is not enough for an event that must use the
/// settings in force when it happened: its own task can run after a later
/// change. Such an event reads through `read`, which takes its place in the
/// queue, and continues outside the queue with that value. Later changes wait
/// only for the read, never for long work that follows it, so draining the
/// queue at shutdown cannot wait on a network operation.
public final class DesktopSettingsQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    public init() {}

    /// Runs `operation` after every earlier submission and before every later one.
    @discardableResult
    public func submit(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            let previous = tail
            let task = Task {
                await previous?.value
                await operation()
            }
            tail = task
            return task
        }
    }

    /// The value as of this point in submission order, however late its
    /// consumer runs.
    public func read<Value: Sendable>(_ operation: @escaping @Sendable () async -> Value) -> Task<Value, Never> {
        lock.withLock {
            let previous = tail
            let task = Task { () -> Value in
                await previous?.value
                return await operation()
            }
            tail = Task { _ = await task.value }
            return task
        }
    }

    /// Completes once everything submitted so far has finished.
    public var current: Task<Void, Never>? { lock.withLock { tail } }

    /// Waits for everything submitted before this call.
    public func drain() async { await current?.value }
}
