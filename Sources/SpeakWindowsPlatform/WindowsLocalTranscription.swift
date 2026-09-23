import Foundation
import SpeakCore
import SpeakDesktop
import CWindowsSupport

public struct WindowsLocalTranscriptionError: LocalizedError, Sendable, Equatable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// SHA-256 through Windows CNG, for verifying downloaded models.
public final class WindowsSHA256Hasher: LocalModelSHA256Hasher {
    private var native: OpaquePointer?

    public init() throws {
        var error = [CChar](repeating: 0, count: 512)
        guard let native = jsti_sha256_create(&error, error.count) else {
            throw LocalModelDigestError.unavailable(String(cString: error))
        }
        self.native = native
    }

    deinit { jsti_sha256_destroy(native) }

    public func update(_ bytes: UnsafeRawBufferPointer) throws {
        guard let native else { throw LocalModelDigestError.reused }
        var error = [CChar](repeating: 0, count: 512)
        guard jsti_sha256_update(native, bytes.baseAddress, bytes.count, &error, error.count) == 0 else {
            throw LocalModelDigestError.unavailable(String(cString: error))
        }
    }

    public func finish() throws -> String {
        guard let native else { throw LocalModelDigestError.reused }
        var hex = [CChar](repeating: 0, count: 65)
        var error = [CChar](repeating: 0, count: 512)
        let status = jsti_sha256_finish(native, &hex, hex.count, &error, error.count)
        jsti_sha256_destroy(native)
        self.native = nil
        guard status == 0 else { throw LocalModelDigestError.unavailable(String(cString: error)) }
        return String(cString: hex)
    }

    public static var provider: LocalModelDigestProvider {
        LocalModelDigestProvider(name: "Windows CNG SHA-256") { try WindowsSHA256Hasher() }
    }
}

/// The process-wide whisper.cpp runtime shipped beside the executable.
public final class WindowsWhisperRuntime: @unchecked Sendable {
    /// The DLL directory: `JSTI_WHISPER_RUNTIME_DIRECTORY` for developer
    /// builds and tests, otherwise the executable's own directory.
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["JSTI_WHISPER_RUNTIME_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    }

    private let native: OpaquePointer
    public let directory: URL
    public let description: String
    public let usesGPU: Bool

    private init(native: OpaquePointer, directory: URL) {
        self.native = native
        self.directory = directory
        var text = [CChar](repeating: 0, count: 1_024)
        jsti_whisper_runtime_describe(native, &text, text.count)
        description = String(cString: text)
        usesGPU = jsti_whisper_runtime_uses_gpu(native) == 1
    }

    private static let lock = NSLock()
    private static var opened: WindowsWhisperRuntime?

    /// Loads the runtime once. Loading reads DLLs and registers backends, so
    /// call it off the UI thread.
    public static func open(directory: URL = defaultDirectory, allowGPU: Bool) throws -> WindowsWhisperRuntime {
        try lock.withLock {
            // One runtime per process: a different directory is refused natively.
            let requested = directory.standardizedFileURL.path
            if let existing = opened, existing.directory.standardizedFileURL.path == requested { return existing }
            var error = [CChar](repeating: 0, count: 1_024)
            let opened = directory.path.withCString {
                jsti_whisper_runtime_open($0, allowGPU ? 1 : 0, &error, error.count)
            }
            guard let native = opened else { throw WindowsLocalTranscriptionError(String(cString: error)) }
            let runtime = WindowsWhisperRuntime(native: native, directory: directory)
            Self.opened = runtime
            return runtime
        }
    }

    /// Frees the cached model after the current transcription, if any,
    /// whichever model it is.
    public func releaseModel() { jsti_whisper_runtime_release_model(native) }

    /// Frees the cached model after the current transcription only if it was
    /// loaded from `modelFile`, which may already be deleted. A model loaded in
    /// its place stays cached. Returns whether that model was freed.
    @discardableResult
    public func releaseModel(loadedFrom modelFile: URL) -> Bool {
        modelFile.path.withCString { jsti_whisper_runtime_release_model_at(native, $0) } == 1
    }

    /// Runs whisper.cpp on a dedicated thread; task cancellation aborts it.
    public func transcribe(
        samples: [Float], modelFile: URL, language: String?, threads: Int = 0
    ) async throws -> String {
        let job = WhisperJob()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let request = Request(samples: samples, modelFile: modelFile, language: language, threads: threads)
                let thread = Thread { [self] in
                    continuation.resume(with: Self.run(native: native, job: job, request: request))
                }
                thread.name = "JustSpeakToIt local transcription"
                thread.stackSize = 8 << 20
                thread.start()
            }
        } onCancel: { job.cancel() }
    }

    private struct Request: Sendable {
        let samples: [Float]
        let modelFile: URL
        let language: String?
        let threads: Int
    }

    private static func run(native: OpaquePointer, job: WhisperJob, request: Request) -> Result<String, Error> {
        var error = [CChar](repeating: 0, count: 1_024)
        var text: UnsafeMutablePointer<CChar>?
        let path = request.modelFile.path
        let status = request.samples.withUnsafeBufferPointer { buffer in
            path.withCString { path in
                withOptionalCString(request.language) { language in
                    jsti_whisper_transcribe(
                        native, path, buffer.baseAddress, buffer.count, language, Int32(request.threads), job.native,
                        &text, &error, error.count
                    )
                }
            }
        }
        defer { jsti_whisper_free_text(text) }
        switch status {
        case 0:
            return .success(text.map { String(cString: $0) } ?? "")
        case 1:
            return .failure(CancellationError())
        default:
            return .failure(WindowsLocalTranscriptionError(String(cString: error)))
        }
    }
}

private func withOptionalCString<Result>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> Result) -> Result {
    guard let value else { return body(nil) }
    return value.withCString { body($0) }
}

private final class WhisperJob: @unchecked Sendable {
    let native: OpaquePointer

    init() {
        // Allocation of an atomic flag; failure means the process is out of memory.
        native = jsti_whisper_job_create()!
    }

    deinit { jsti_whisper_job_destroy(native) }

    func cancel() { jsti_whisper_job_cancel(native) }
}

/// `DesktopLocalRecognizer` over the bundled whisper.cpp runtime.
public struct WindowsWhisperRecognizer: DesktopLocalRecognizer {
    private let runtime: WindowsWhisperRuntime

    public init(runtime: WindowsWhisperRuntime) { self.runtime = runtime }

    public func transcribe(
        samples: [Float], modelFile: URL, model: WhisperCppModel, language: String?
    ) async throws -> String {
        try await runtime.transcribe(samples: samples, modelFile: modelFile, language: language)
    }
}
