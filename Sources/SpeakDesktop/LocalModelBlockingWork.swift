import Foundation

/// Runs long blocking file, digest and native work on a dedicated thread, so
/// neither the UI thread nor the Swift concurrency pool waits on it.
/// Cancellation is cooperative through `LocalModelCancellation`.
enum LocalModelBlockingWork {
    static func run<Value: Sendable>(
        name: String, _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try work() })
            }
            thread.name = name
            thread.start()
        }
    }
}
