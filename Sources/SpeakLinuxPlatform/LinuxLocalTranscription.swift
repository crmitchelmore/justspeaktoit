import Foundation
import CLinuxSupport
import SpeakCore
import SpeakDesktop

/// SHA-256 through GLib, for verifying downloaded models.
public final class LinuxSHA256Hasher: LocalModelSHA256Hasher {
    private var native: OpaquePointer?

    public init() throws {
        var error = [CChar](repeating: 0, count: 256)
        guard let native = jsti_sha256_create(&error, error.count) else {
            throw LocalModelDigestError.unavailable(String(cString: error))
        }
        self.native = native
    }

    deinit { jsti_sha256_destroy(native) }

    public func update(_ bytes: UnsafeRawBufferPointer) throws {
        guard let native else { throw LocalModelDigestError.reused }
        var error = [CChar](repeating: 0, count: 256)
        guard jsti_sha256_update(native, bytes.baseAddress, bytes.count, &error, error.count) == 0 else {
            throw LocalModelDigestError.unavailable(String(cString: error))
        }
    }

    public func finish() throws -> String {
        guard let native else { throw LocalModelDigestError.reused }
        var hex = [CChar](repeating: 0, count: 65)
        var error = [CChar](repeating: 0, count: 256)
        let status = jsti_sha256_finish(native, &hex, hex.count, &error, error.count)
        jsti_sha256_destroy(native)
        self.native = nil
        guard status == 0 else { throw LocalModelDigestError.unavailable(String(cString: error)) }
        return String(cString: hex)
    }

    public static var provider: LocalModelDigestProvider {
        LocalModelDigestProvider(name: "GLib SHA-256") { try LinuxSHA256Hasher() }
    }
}

public struct LinuxLocalTranscriptionError: LocalizedError, Sendable, Equatable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// The process-wide whisper.cpp runtime installed with the app.
public final class LinuxWhisperRuntime: @unchecked Sendable {
    /// `JSTI_WHISPER_LIBRARY_DIR` for developer builds and tests, otherwise
    /// `<executable dir>/../lib/justspeaktoit` (`/app/lib/justspeaktoit` in the
    /// Flatpak, `/usr/lib/justspeaktoit` in a package).
    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["JSTI_WHISPER_LIBRARY_DIR"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let executable = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe"))
            ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("lib/justspeaktoit", isDirectory: true)
            .standardizedFileURL
    }

    /// Whether the runtime's main library is installed in `directory`.
    public static func isInstalled(in directory: URL = defaultDirectory()) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("libwhisper.so.1").path)
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
    private static var opened: LinuxWhisperRuntime?

    /// Loads the runtime once. Loading maps libraries and registers backends,
    /// so call it off the UI thread.
    public static func open(directory: URL = defaultDirectory(), allowGPU: Bool) throws -> LinuxWhisperRuntime {
        try lock.withLock {
            let requested = directory.standardizedFileURL.path
            if let existing = opened, existing.directory.standardizedFileURL.path == requested { return existing }
            var error = [CChar](repeating: 0, count: 1_024)
            guard let native = jsti_whisper_runtime_open(requested, allowGPU ? 1 : 0, &error, error.count) else {
                throw LinuxLocalTranscriptionError(String(cString: error))
            }
            let runtime = LinuxWhisperRuntime(native: native, directory: directory)
            Self.opened = runtime
            return runtime
        }
    }

    /// Frees the cached model after the current transcription only if it was
    /// loaded from `modelFile`. Returns whether that model was freed.
    @discardableResult
    public func releaseModel(loadedFrom modelFile: URL) -> Bool {
        jsti_whisper_runtime_release_model_at(native, modelFile.path) == 1
    }

    /// Runs whisper.cpp on a dedicated thread; task cancellation aborts it.
    public func transcribe(
        samples: [Float], modelFile: URL, language: String?, threads: Int = 0
    ) async throws -> String {
        let job = LinuxWhisperJob()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let thread = Thread { [self] in
                    continuation.resume(with: Self.run(
                        native: native, job: job, samples: samples, modelFile: modelFile, language: language,
                        threads: threads
                    ))
                }
                thread.name = "JustSpeakToIt local transcription"
                thread.stackSize = 8 << 20
                thread.start()
            }
        } onCancel: { job.cancel() }
    }

    // The native call's parameters are fixed by the C ABI.
    // swiftlint:disable:next function_parameter_count
    private static func run(
        native: OpaquePointer, job: LinuxWhisperJob, samples: [Float], modelFile: URL, language: String?, threads: Int
    ) -> Result<String, Error> {
        var error = [CChar](repeating: 0, count: 1_024)
        var text: UnsafeMutablePointer<CChar>?
        let status = samples.withUnsafeBufferPointer { buffer in
            withOptionalCString(language) { language in
                jsti_whisper_transcribe(
                    native, modelFile.path, buffer.baseAddress, buffer.count, language, Int32(threads), job.native,
                    &text, &error, error.count
                )
            }
        }
        defer { jsti_whisper_free_text(text) }
        switch status {
        case Int32(JSTI_WHISPER_OK): return .success(text.map { String(cString: $0) } ?? "")
        case Int32(JSTI_WHISPER_CANCELLED): return .failure(CancellationError())
        default: return .failure(LinuxLocalTranscriptionError(String(cString: error)))
        }
    }
}

private func withOptionalCString<Result>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> Result) -> Result {
    guard let value else { return body(nil) }
    return value.withCString { body($0) }
}

private final class LinuxWhisperJob: @unchecked Sendable {
    let native: OpaquePointer

    init() {
        // A small allocation; failure means the process is out of memory.
        native = jsti_whisper_job_create()!
    }

    deinit { jsti_whisper_job_destroy(native) }

    func cancel() { jsti_whisper_job_cancel(native) }
}

/// `DesktopLocalRecognizer` over the installed whisper.cpp runtime.
public struct LinuxWhisperRecognizer: DesktopLocalRecognizer {
    private let runtime: LinuxWhisperRuntime

    public init(runtime: LinuxWhisperRuntime) { self.runtime = runtime }

    public func transcribe(
        samples: [Float], modelFile: URL, model: WhisperCppModel, language: String?
    ) async throws -> String {
        try await runtime.transcribe(samples: samples, modelFile: modelFile, language: language)
    }
}
