import Foundation

/// Crosses desktop UI events into async state with one in-flight handler and
/// a bounded list of pending events, performed in submission order.
/// Scheduling cannot reorder them, and a burst cannot create a Task or
/// retained closure for every native event. By default only the latest
/// pending event is kept; a coalescing rule may keep more, provided it keeps
/// the list bounded.
public final class DesktopEventDispatcher<Event: Sendable>: @unchecked Sendable {
    typealias Launcher = @Sendable (@escaping @Sendable () async -> Void) -> Void
    /// Folds a newly submitted event into those still pending, oldest first.
    public typealias Coalescing = @Sendable (inout [Event], Event) -> Void
    private let lock = NSLock()
    private var pending: [Event] = []
    private var draining = false
    private let launch: Launcher
    private let coalesce: Coalescing
    private let perform: @Sendable (Event) async -> Void

    public convenience init(perform: @escaping @Sendable (Event) async -> Void) {
        self.init(launch: { operation in Task { await operation() } }, perform: perform)
    }

    public convenience init(coalescing: @escaping Coalescing, perform: @escaping @Sendable (Event) async -> Void) {
        self.init(launch: { operation in Task { await operation() } }, coalescing: coalescing, perform: perform)
    }

    init(
        launch: @escaping Launcher, coalescing: @escaping Coalescing = { $0 = [$1] },
        perform: @escaping @Sendable (Event) async -> Void
    ) {
        self.launch = launch
        self.coalesce = coalescing
        self.perform = perform
    }

    public func submit(_ event: Event) {
        let start = lock.withLock {
            coalesce(&pending, event)
            guard !draining, !pending.isEmpty else { return false }
            draining = true
            return true
        }
        guard start else { return }
        launch { [self] in
            while let next = self.next() { await self.perform(next) }
        }
    }

    private func next() -> Event? {
        lock.withLock {
            guard !pending.isEmpty else { draining = false; return nil }
            return pending.removeFirst()
        }
    }
}
