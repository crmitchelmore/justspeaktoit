import CLlamaRuntime
import Foundation

/// Why the compiled-in llama.cpp runtime stopped. Raw values are the
/// `JSTI_LLAMA_*` codes in `jsti_llama_runtime.h`.
public enum LlamaRuntimeFailure: Int32, Error, Sendable {
    case aborted = 1
    case noChatTemplate = 2
    case tooLong = 3
    case decode = 4
    case noEndOfTurn = 5
    case invalidOutput = 6
    case context = 7
    case timedOut = 8
}

public struct LlamaRuntimeError: Error, Equatable, Sendable {
    public enum Stage: Sendable { case load, complete }

    public let stage: Stage
    /// `nil` when the runtime reported an unknown code.
    public let failure: LlamaRuntimeFailure?
    public let code: Int32
}

/// One load, completion and free of a GGUF model, on the calling thread.
///
/// `abort` lets another thread stop a running load or completion; the
/// session is freed only after both have returned.
public final class LlamaRuntimeRun: @unchecked Sendable {
    private let lock = NSLock()
    private var session: OpaquePointer?
    private var aborted = false

    public init() {}

    /// The model's reply to `system` and `user`, using its chat template.
    public func complete(
        modelFile: URL, system: String, user: String, timeout: TimeInterval, maxTokens: Int32 = 2_048,
        threads: Int32 = LlamaRuntimeRun.defaultThreads
    ) throws -> String {
        guard let created = jsti_llama_create(Int64((timeout * 1_000).rounded())) else {
            throw LlamaRuntimeError(stage: .load, failure: .context, code: LlamaRuntimeFailure.context.rawValue)
        }
        lock.lock()
        session = created
        if aborted { jsti_llama_abort(created) }
        lock.unlock()
        defer {
            lock.lock()
            session = nil
            lock.unlock()
            jsti_llama_free(created)
        }
        guard modelFile.withUnsafeFileSystemRepresentation({ path in
            path.map { jsti_llama_load(created, $0) } ?? false
        }) else {
            throw error(created, stage: .load)
        }
        guard let reply = jsti_llama_complete(created, system, user, maxTokens, threads) else {
            throw error(created, stage: .complete)
        }
        defer { jsti_llama_free_string(reply) }
        return String(cString: reply)
    }

    /// Stops the current or next load or completion at its next check.
    public func abort() {
        lock.lock()
        aborted = true
        if let session { jsti_llama_abort(session) }
        lock.unlock()
    }

    private func error(_ session: OpaquePointer, stage: LlamaRuntimeError.Stage) -> LlamaRuntimeError {
        let code = jsti_llama_last_error(session)
        return LlamaRuntimeError(stage: stage, failure: LlamaRuntimeFailure(rawValue: code), code: code)
    }

    /// Performance cores only, at most four: efficiency cores slow ggml's
    /// threads down to their pace.
    public static var defaultThreads: Int32 {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return min(count, 4)
        }
        return Int32(max(1, min(ProcessInfo.processInfo.activeProcessorCount / 2, 4)))
    }
}
