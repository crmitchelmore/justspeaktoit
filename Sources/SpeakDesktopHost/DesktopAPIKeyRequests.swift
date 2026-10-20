import Foundation

/// Admission is synchronous; keyring and provider work never occupies a settings queue.
package final class DesktopAPIKeyRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var request: UUID?
    private var stopped = false

    package init() {}

    @discardableResult
    package func start(_ identifier: UUID, operation: @escaping @Sendable () async -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, task == nil else { return false }
        request = identifier
        task = Task {
            await operation()
            self.finished(identifier)
        }
        return true
    }

    package func cancel(_ identifier: UUID) {
        lock.withLock {
            if request == identifier { task?.cancel() }
        }
    }

    package func stop() {
        lock.withLock {
            stopped = true
            task?.cancel()
        }
    }

    package func drain() async {
        await lock.withLock { task }?.value
    }

    private func finished(_ identifier: UUID) {
        lock.withLock {
            guard request == identifier else { return }
            task = nil
            request = nil
        }
    }
}
