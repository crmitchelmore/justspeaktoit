import Foundation

/// Admission follows the underlying operation, not the caller's deadline.
public final class DesktopComparisonOperations: @unchecked Sendable {
    public static let capacity = 8
    private let lock = NSLock()
    private var records: [UUID: Record] = [:]

    public init() {}

    public var activeCount: Int { lock.withLock { records.count } }

    public func cancelAll() {
        let active = lock.withLock { Array(records.values) }
        active.forEach { $0.cancel() }
    }

    package func run<Value: Sendable>(
        timeout: Duration,
        admitted: @escaping @Sendable (UUID) async throws -> Void,
        exited: @escaping @Sendable (UUID) async -> Void,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let id = UUID()
        let record = Record()
        try lock.withLock {
            guard records.count < Self.capacity else {
                throw DesktopComparisonError.message(
                    "All eight comparison operation slots are still owned. Wait for providers to finish."
                )
            }
            records[id] = record
        }
        return try await withTaskCancellationHandler {
            do { try await admitted(id) } catch {
                await exited(id)
                remove(id)
                throw error
            }
            let task = Task {
                do {
                    try Task.checkCancellation()
                    try record.checkCancellation()
                    let value = try await operation()
                    await exited(id)
                    self.remove(id)
                    return value
                } catch {
                    await exited(id)
                    self.remove(id)
                    throw error
                }
            }
            record.install { task.cancel() }
            do {
                return try await DesktopComparisonDeadline.run(timeout: timeout) { try await task.value }
            } catch {
                record.cancel()
                throw error
            }
        } onCancel: { record.cancel() }
    }

    private func remove(_ id: UUID) { lock.withLock { _ = records.removeValue(forKey: id) } }

    private final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var cancelWork: (@Sendable () -> Void)?

        func install(_ cancel: @escaping @Sendable () -> Void) {
            let cancelNow = lock.withLock {
                cancelWork = cancel
                return cancelled
            }
            if cancelNow { cancel() }
        }

        func cancel() {
            let work = lock.withLock { cancelled = true; return cancelWork }
            work?()
        }

        func checkCancellation() throws {
            try lock.withLock { if cancelled { throw CancellationError() } }
        }
    }
}
