import Foundation

/// The caller awaits native teardown. Cancellation is cooperative and never abandons a worker.
public enum VoiceAudioCodecWorker {
    public final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        public var isCancelled: Bool { lock.withLock { cancelled } }
        fileprivate func cancel() { lock.withLock { cancelled = true } }
    }

    public static func run<Value: Sendable>(
        _ operation: @escaping @Sendable (Cancellation) throws -> Value
    ) async throws -> Value {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: Value = try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(with: Result {
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        return try operation(cancellation)
                    })
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: { cancellation.cancel() }
    }
}
