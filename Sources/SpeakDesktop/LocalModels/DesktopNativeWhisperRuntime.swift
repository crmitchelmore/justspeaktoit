import Foundation
import SpeakCore

/// The whisper.cpp and SHA-256 entry points of the Windows and Linux native
/// adapters. Both hosts export the same C ABI; each supplies its functions here.
/// It holds only C function references, so sharing it is safe.
public struct DesktopNativeLocalTranscriptionBridge: @unchecked Sendable {
    public typealias ErrorBuffer = UnsafeMutablePointer<CChar>

    public let sha256Create: (ErrorBuffer?, Int) -> OpaquePointer?
    public let sha256Update: (OpaquePointer?, UnsafeRawPointer?, Int, ErrorBuffer?, Int) -> Int32
    public let sha256Finish: (OpaquePointer?, ErrorBuffer?, Int, ErrorBuffer?, Int) -> Int32
    public let sha256Destroy: (OpaquePointer?) -> Void
    public let runtimeOpen: (UnsafePointer<CChar>?, Int32, ErrorBuffer?, Int) -> OpaquePointer?
    public let runtimeDescribe: (OpaquePointer?, ErrorBuffer?, Int) -> Int32
    public let runtimeUsesGPU: (OpaquePointer?) -> Int32
    public let releaseModel: (OpaquePointer?) -> Void
    public let releaseModelAt: (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
    public let jobCreate: () -> OpaquePointer?
    public let jobCancel: (OpaquePointer?) -> Void
    public let jobDestroy: (OpaquePointer?) -> Void
    /// runtime, model path, model SHA-256, samples, count, language, threads, job, text, error, capacity.
    public let transcribe: (
        OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<Float>?, Int,
        UnsafePointer<CChar>?, Int32, OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        ErrorBuffer?, Int
    ) -> Int32
    public let freeText: (UnsafeMutablePointer<CChar>?) -> Void
    /// Names the hasher in digest errors, e.g. "Windows CNG SHA-256".
    public let digestName: String

    public init(
        sha256Create: @escaping (ErrorBuffer?, Int) -> OpaquePointer?,
        sha256Update: @escaping (OpaquePointer?, UnsafeRawPointer?, Int, ErrorBuffer?, Int) -> Int32,
        sha256Finish: @escaping (OpaquePointer?, ErrorBuffer?, Int, ErrorBuffer?, Int) -> Int32,
        sha256Destroy: @escaping (OpaquePointer?) -> Void,
        runtimeOpen: @escaping (UnsafePointer<CChar>?, Int32, ErrorBuffer?, Int) -> OpaquePointer?,
        runtimeDescribe: @escaping (OpaquePointer?, ErrorBuffer?, Int) -> Int32,
        runtimeUsesGPU: @escaping (OpaquePointer?) -> Int32,
        releaseModel: @escaping (OpaquePointer?) -> Void,
        releaseModelAt: @escaping (OpaquePointer?, UnsafePointer<CChar>?) -> Int32,
        jobCreate: @escaping () -> OpaquePointer?,
        jobCancel: @escaping (OpaquePointer?) -> Void,
        jobDestroy: @escaping (OpaquePointer?) -> Void,
        transcribe: @escaping (
            OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<Float>?, Int,
            UnsafePointer<CChar>?, Int32, OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
            ErrorBuffer?, Int
        ) -> Int32,
        freeText: @escaping (UnsafeMutablePointer<CChar>?) -> Void,
        digestName: String
    ) {
        self.sha256Create = sha256Create
        self.sha256Update = sha256Update
        self.sha256Finish = sha256Finish
        self.sha256Destroy = sha256Destroy
        self.runtimeOpen = runtimeOpen
        self.runtimeDescribe = runtimeDescribe
        self.runtimeUsesGPU = runtimeUsesGPU
        self.releaseModel = releaseModel
        self.releaseModelAt = releaseModelAt
        self.jobCreate = jobCreate
        self.jobCancel = jobCancel
        self.jobDestroy = jobDestroy
        self.transcribe = transcribe
        self.freeText = freeText
        self.digestName = digestName
    }

    /// `JSTIWhisperResult`, identical in both adapters.
    enum Status: Int32 {
        case ok = 0, cancelled = 1, modelMismatch = 2
    }
}

public struct DesktopNativeLocalTranscriptionError: LocalizedError, Sendable, Equatable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// SHA-256 through the platform's native hasher, for verifying downloaded models.
public final class DesktopNativeSHA256Hasher: LocalModelSHA256Hasher {
    private let bridge: DesktopNativeLocalTranscriptionBridge
    private var native: OpaquePointer?

    public init(bridge: DesktopNativeLocalTranscriptionBridge) throws {
        self.bridge = bridge
        var error = [CChar](repeating: 0, count: 512)
        guard let native = bridge.sha256Create(&error, error.count) else {
            throw LocalModelDigestError.unavailable(String(cString: error))
        }
        self.native = native
    }

    deinit { bridge.sha256Destroy(native) }

    public func update(_ bytes: UnsafeRawBufferPointer) throws {
        guard let native else { throw LocalModelDigestError.reused }
        var error = [CChar](repeating: 0, count: 512)
        guard bridge.sha256Update(native, bytes.baseAddress, bytes.count, &error, error.count) == 0 else {
            throw LocalModelDigestError.unavailable(String(cString: error))
        }
    }

    public func finish() throws -> String {
        guard let native else { throw LocalModelDigestError.reused }
        var hex = [CChar](repeating: 0, count: 65)
        var error = [CChar](repeating: 0, count: 512)
        let status = bridge.sha256Finish(native, &hex, hex.count, &error, error.count)
        bridge.sha256Destroy(native)
        self.native = nil
        guard status == 0 else { throw LocalModelDigestError.unavailable(String(cString: error)) }
        return String(cString: hex)
    }

    public static func digestProvider(_ bridge: DesktopNativeLocalTranscriptionBridge) -> LocalModelDigestProvider {
        LocalModelDigestProvider(name: bridge.digestName) { try DesktopNativeSHA256Hasher(bridge: bridge) }
    }
}

/// The process-wide whisper.cpp runtime shipped beside the executable.
public final class DesktopNativeWhisperRuntime: @unchecked Sendable {
    private let bridge: DesktopNativeLocalTranscriptionBridge
    private let native: OpaquePointer
    public let directory: URL
    public let description: String
    public let usesGPU: Bool

    private init(bridge: DesktopNativeLocalTranscriptionBridge, native: OpaquePointer, directory: URL) {
        self.bridge = bridge
        self.native = native
        self.directory = directory
        var text = [CChar](repeating: 0, count: 1_024)
        _ = bridge.runtimeDescribe(native, &text, text.count)
        description = String(cString: text)
        usesGPU = bridge.runtimeUsesGPU(native) == 1
    }

    private static let lock = NSLock()
    private static var opened: DesktopNativeWhisperRuntime?

    /// Loads the runtime once. Loading reads libraries and registers backends,
    /// so call it off the UI thread.
    public static func open(
        bridge: DesktopNativeLocalTranscriptionBridge, directory: URL, allowGPU: Bool
    ) throws -> DesktopNativeWhisperRuntime {
        try lock.withLock {
            // One runtime per process: a different directory is refused natively.
            let requested = directory.standardizedFileURL.path
            if let existing = opened, existing.directory.standardizedFileURL.path == requested { return existing }
            var error = [CChar](repeating: 0, count: 1_024)
            let opened = directory.path.withCString { bridge.runtimeOpen($0, allowGPU ? 1 : 0, &error, error.count) }
            guard let native = opened else { throw DesktopNativeLocalTranscriptionError(String(cString: error)) }
            let runtime = DesktopNativeWhisperRuntime(bridge: bridge, native: native, directory: directory)
            Self.opened = runtime
            return runtime
        }
    }

    /// Frees the cached model after the current transcription, if any,
    /// whichever model it is.
    public func releaseModel() { bridge.releaseModel(native) }

    /// Frees the cached model after the current transcription only if it was
    /// loaded from `modelFile`, which may already be deleted. A model loaded in
    /// its place stays cached. Returns whether that model was freed.
    @discardableResult
    public func releaseModel(loadedFrom modelFile: URL) -> Bool {
        modelFile.path.withCString { bridge.releaseModelAt(native, $0) } == 1
    }

    /// Runs whisper.cpp on a dedicated thread; task cancellation aborts it.
    /// Loading hashes the bytes the runtime reads, and only bytes whose
    /// SHA-256 is `modelSHA256` are used; otherwise it throws
    /// `DesktopLocalTranscriptionError.modelDoesNotMatchDigest`.
    public func transcribe(
        samples: [Float], modelFile: URL, modelSHA256: String, language: String?, threads: Int = 0
    ) async throws -> String {
        let job = WhisperJob(bridge: bridge)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let request = Request(
                    samples: samples, modelFile: modelFile, modelSHA256: modelSHA256, language: language,
                    threads: threads
                )
                let thread = Thread { [self] in
                    continuation.resume(with: Self.run(bridge: bridge, native: native, job: job, request: request))
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
        let modelSHA256: String
        let language: String?
        let threads: Int
    }

    private static func run(
        bridge: DesktopNativeLocalTranscriptionBridge, native: OpaquePointer, job: WhisperJob, request: Request
    ) -> Result<String, Error> {
        var error = [CChar](repeating: 0, count: 1_024)
        var text: UnsafeMutablePointer<CChar>?
        let path = request.modelFile.path
        let status = request.samples.withUnsafeBufferPointer { buffer in
            path.withCString { path in
                request.modelSHA256.withCString { digest in
                    withOptionalCString(request.language) { language in
                        bridge.transcribe(
                            native, path, digest, buffer.baseAddress, buffer.count, language, Int32(request.threads),
                            job.native, &text, &error, error.count
                        )
                    }
                }
            }
        }
        defer { bridge.freeText(text) }
        switch DesktopNativeLocalTranscriptionBridge.Status(rawValue: status) {
        case .ok: return .success(text.map { String(cString: $0) } ?? "")
        case .cancelled: return .failure(CancellationError())
        case .modelMismatch: return .failure(DesktopLocalTranscriptionError.modelDoesNotMatchDigest)
        case nil: return .failure(DesktopNativeLocalTranscriptionError(String(cString: error)))
        }
    }
}

private func withOptionalCString<Result>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> Result) -> Result {
    guard let value else { return body(nil) }
    return value.withCString { body($0) }
}

private final class WhisperJob: @unchecked Sendable {
    private let bridge: DesktopNativeLocalTranscriptionBridge
    let native: OpaquePointer

    init(bridge: DesktopNativeLocalTranscriptionBridge) {
        self.bridge = bridge
        // An allocation of one atomic flag; failure means the process is out of memory.
        native = bridge.jobCreate()!
    }

    deinit { bridge.jobDestroy(native) }

    func cancel() { bridge.jobCancel(native) }
}

/// `DesktopLocalRecognizer` over the whisper.cpp runtime.
public struct DesktopNativeWhisperRecognizer: DesktopLocalRecognizer {
    private let runtime: DesktopNativeWhisperRuntime

    public init(runtime: DesktopNativeWhisperRuntime) { self.runtime = runtime }

    public func transcribe(
        samples: [Float], modelFile: URL, model: WhisperCppModel, language: String?
    ) async throws -> String {
        try await runtime.transcribe(
            samples: samples, modelFile: modelFile, modelSHA256: model.artifact.sha256, language: language
        )
    }
}
