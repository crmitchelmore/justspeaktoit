import Foundation

/// A file decode owns its stop flag. WhisperKit checks the progress callback at
/// supported token boundaries; an in-flight Core ML operation must still unwind.
final class WhisperKitFileCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var shouldContinue: Bool { lock.withLock { !cancelled } }
    private func cancel() { lock.withLock { cancelled = true } }

    static func run<Value: Sendable>(
        operation: (WhisperKitFileCancellation) async throws -> Value
    ) async throws -> Value {
        let request = WhisperKitFileCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value = try await operation(request)
            try Task.checkCancellation()
            return value
        } onCancel: {
            request.cancel()
        }
    }
}
