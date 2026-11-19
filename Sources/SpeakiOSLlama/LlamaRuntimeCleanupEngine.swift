#if os(iOS)
import Foundation
import SpeakCore
import SpeakiOSLib

/// The iOS cleanup engine: llama.cpp compiled into the app, CPU only. Loads
/// the verified model for each cleanup and frees it afterwards, one cleanup at
/// a time, so no model stays resident between recordings.
public final class LlamaRuntimeCleanupEngine: IOSLocalCleanupEngine, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.justspeaktoit.local-cleanup", qos: .userInitiated)
    private let lock = NSLock()
    private var running: LlamaRuntimeRun?

    public init() {}

    public func complete(
        modelFile: URL, systemPrompt: String, userMessage: String, timeout: TimeInterval
    ) async throws -> String {
        let name = IOSLocalCleanupModels.all.first { $0.artifact.filename == modelFile.lastPathComponent }?
            .displayName ?? modelFile.lastPathComponent
        let run = LlamaRuntimeRun()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                queue.async { [self] in
                    lock.lock()
                    running = run
                    lock.unlock()
                    defer {
                        lock.lock()
                        if running === run { running = nil }
                        lock.unlock()
                    }
                    do {
                        let reply = try run.complete(
                            modelFile: modelFile, system: systemPrompt, user: userMessage, timeout: timeout
                        )
                        continuation.resume(returning: reply)
                    } catch let error as LlamaRuntimeError {
                        continuation.resume(throwing: Self.cleanupError(error, name: name))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            run.abort()
        }
    }

    public func releaseMemory() {
        lock.lock()
        let run = running
        lock.unlock()
        run?.abort()
    }

    static func cleanupError(_ error: LlamaRuntimeError, name: String) -> IOSLocalCleanupError {
        switch error.failure {
        case .timedOut: return .timedOut(name)
        case .aborted: return .stopped(name)
        case .tooLong: return .transcriptTooLong(name)
        case .context where error.stage == .load: return .loadFailed(name)
        default: return .runtimeFailed(name, code: error.code)
        }
    }
}
#endif
