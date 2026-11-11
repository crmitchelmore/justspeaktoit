import Foundation

/// Adapts system permission callbacks without making cancellation wait for the
/// user to dismiss the system prompt. Late or duplicate callbacks are ignored;
/// callers still check task cancellation before acquiring recording resources.
public enum CancellablePermissionRequest {
    @MainActor
    public static func request(
        _ begin: (@escaping @Sendable (Bool) -> Void) -> Void
    ) async -> Bool {
        let state = PermissionContinuation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.install(continuation) else { return }
                begin { state.resolve($0) }
            }
        } onCancel: {
            state.resolve(false)
        }
    }
}

private final class PermissionContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func install(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func resolve(_ result: Bool) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
