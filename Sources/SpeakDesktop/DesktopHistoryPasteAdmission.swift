import Foundation

/// Bounds captured targets before they reach the Host's separate output slot.
/// An expired request retains its slot until its queued consumer actually returns.
package final class DesktopHistoryPasteAdmission: @unchecked Sendable {
    package struct Request: Sendable {
        fileprivate let owner: DesktopHistoryPasteAdmission
        fileprivate let id: UUID
        fileprivate let deadline: ContinuousClock.Instant

        package var isCurrent: Bool { owner.isCurrent(self) }
        package func finish() { owner.finish(self) }
    }

    package static let maximumDelay: Duration = .seconds(1)
    private let lock = NSLock()
    private let now: @Sendable () -> ContinuousClock.Instant
    private var pending: UUID?
    private var stopped = false

    package init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    /// Call before native target capture, not from the queued consumer.
    package func begin() -> Request? {
        lock.withLock {
            guard !stopped, pending == nil else { return nil }
            let id = UUID()
            pending = id
            return Request(owner: self, id: id, deadline: now().advanced(by: Self.maximumDelay))
        }
    }

    package func stop() {
        lock.withLock {
            stopped = true
            pending = nil
        }
    }

    private func isCurrent(_ request: Request) -> Bool {
        lock.withLock { !stopped && pending == request.id && now() < request.deadline }
    }

    private func finish(_ request: Request) {
        lock.withLock {
            if pending == request.id { pending = nil }
        }
    }
}
