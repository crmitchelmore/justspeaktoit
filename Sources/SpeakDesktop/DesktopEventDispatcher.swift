import Foundation

/// Crosses desktop UI events into async state with one in-flight handler and
/// one latest pending event. Scheduling cannot reorder selection updates, and
/// a burst cannot create a Task or retained closure for every native event.
public final class DesktopEventDispatcher<Event: Sendable>: @unchecked Sendable {
    typealias Launcher = @Sendable (@escaping @Sendable () async -> Void) -> Void
    private let lock = NSLock()
    private var pending: Event?
    private var draining = false
    private let launch: Launcher
    private let perform: @Sendable (Event) async -> Void

    public convenience init(perform: @escaping @Sendable (Event) async -> Void) {
        self.init(launch: { operation in Task { await operation() } }, perform: perform)
    }

    init(launch: @escaping Launcher, perform: @escaping @Sendable (Event) async -> Void) {
        self.launch = launch
        self.perform = perform
    }

    public func submit(_ event: Event) {
        let start = lock.withLock {
            pending = event
            guard !draining else { return false }
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
            guard let event = pending else { draining = false; return nil }
            pending = nil
            return event
        }
    }
}
