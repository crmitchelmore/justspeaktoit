import Foundation

/// Coalesces native search keystrokes. The UI thread only records the newest
/// query and one task drains it, so a typing burst never queues an actor call
/// per keystroke and the latest query always wins.
final class WindowsSearchCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: String?
    private var draining = false
    private let perform: @Sendable (String) async -> Void

    init(perform: @escaping @Sendable (String) async -> Void) { self.perform = perform }

    func submit(_ query: String) {
        lock.lock()
        pending = query
        let alreadyDraining = draining
        draining = true
        lock.unlock()
        guard !alreadyDraining else { return }
        Task { [self] in
            while let query = self.next() { await self.perform(query) }
        }
    }

    private func next() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let query = pending else { draining = false; return nil }
        pending = nil
        return query
    }
}
