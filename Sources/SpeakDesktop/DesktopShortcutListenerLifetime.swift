import Foundation

/// One native registration attempt. Stop fences admission immediately, while
/// an already-started registration retains its context until actual cleanup.
package final class DesktopShortcutListenerLifetime: @unchecked Sendable {
    private enum Phase {
        case idle, starting, registered((@Sendable () -> Void)?), stopped
    }

    private let lock = NSLock()
    private var phase = Phase.idle

    package init() {}
    deinit { stop() }

    package func begin() -> Bool {
        lock.withLock {
            guard case .idle = phase else { return false }
            phase = .starting
            return true
        }
    }

    /// The cleanup must retain the native callback context until stop returns.
    /// A failed registration supplies nil and may still publish its error hint.
    @discardableResult
    package func finish(cleanup: (@Sendable () -> Void)?) -> Bool {
        let accepted = lock.withLock {
            guard case .starting = phase else { return false }
            phase = .registered(cleanup)
            return true
        }
        if !accepted { cleanup?() }
        return accepted
    }

    private var callbacksAllowed: Bool {
        switch phase {
        case .starting: true
        case .registered(let cleanup): cleanup != nil
        case .idle, .stopped: false
        }
    }

    /// Preflight only. Final dispatch must use `admitCallback` after native preparation.
    package var acceptsCallbacks: Bool { lock.withLock { callbacksAllowed } }

    /// Final bounded enqueue against stop; the body must not reenter this lifetime.
    /// Native capture, IPC and synchronous queue waits belong before this call.
    @discardableResult
    package func admitCallback(_ operation: () -> Void) -> Bool {
        lock.withLock {
            guard callbacksAllowed else { return false }
            operation()
            return true
        }
    }

    /// Only synchronous, bounded publication; the body must not reenter this lifetime.
    @discardableResult
    package func publish(_ operation: () -> Void) -> Bool {
        lock.withLock {
            guard case .registered = phase else { return false }
            operation()
            return true
        }
    }

    package func stop() {
        let cleanup: (@Sendable () -> Void)? = lock.withLock {
            let cleanup: (@Sendable () -> Void)?
            if case .registered(let registered) = phase { cleanup = registered } else { cleanup = nil }
            phase = .stopped
            return cleanup
        }
        cleanup?()
    }
}
