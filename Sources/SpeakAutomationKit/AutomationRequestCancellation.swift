import Foundation
import SpeakCore

/// One request's cancellation ownership. The installed action must be fast/nonblocking.
/// The transport removes it before closing its descriptor, preventing shutdown of a reused FD.
public final class AutomationRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var cancelled = false

    public init() {}

    public func cancel() {
        self.lock.withLock {
            guard !self.cancelled else { return }
            self.cancelled = true
            self.action?()
        }
    }

    var isCancelled: Bool { self.lock.withLock { self.cancelled } }

    func install(_ action: @escaping @Sendable () -> Void) {
        self.lock.withLock {
            self.action = action
            if self.cancelled { action() }
        }
    }

    func uninstall() { self.lock.withLock { self.action = nil } }
}

/// Additive capability; old synchronous clients and injected callers remain supported.
public protocol CancellableAutomationRequesting: AutomationRequesting, Sendable {
    func send(_ request: AutomationRequest, cancellation: AutomationRequestCancellation) throws -> AutomationResponse
}
