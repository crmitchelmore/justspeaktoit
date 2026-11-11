import Foundation
import SpeakCore
import SpeakDesktop
import CWindowsSupport

public typealias WindowsLocalTranscriptionError = DesktopNativeLocalTranscriptionError
public typealias WindowsSHA256Hasher = DesktopNativeSHA256Hasher
public typealias WindowsWhisperRuntime = DesktopNativeWhisperRuntime
public typealias WindowsWhisperRecognizer = DesktopNativeWhisperRecognizer

extension DesktopNativeLocalTranscriptionBridge {
    /// Windows CNG SHA-256 and the bundled whisper.dll.
    public static let windows = DesktopNativeLocalTranscriptionBridge(
        sha256Create: jsti_sha256_create, sha256Update: jsti_sha256_update, sha256Finish: jsti_sha256_finish,
        sha256Destroy: jsti_sha256_destroy, runtimeOpen: jsti_whisper_runtime_open,
        runtimeDescribe: jsti_whisper_runtime_describe, runtimeUsesGPU: jsti_whisper_runtime_uses_gpu,
        releaseModel: jsti_whisper_runtime_release_model, releaseModelAt: jsti_whisper_runtime_release_model_at,
        jobCreate: jsti_whisper_job_create, jobCancel: jsti_whisper_job_cancel, jobDestroy: jsti_whisper_job_destroy,
        transcribe: jsti_whisper_transcribe, freeText: jsti_whisper_free_text, digestName: "Windows CNG SHA-256"
    )
}

extension DesktopNativeSHA256Hasher {
    public convenience init() throws { try self.init(bridge: .windows) }

    public static var provider: LocalModelDigestProvider { digestProvider(.windows) }
}

extension DesktopNativeWhisperRuntime {
    /// The DLL directory: `JSTI_WHISPER_RUNTIME_DIRECTORY` for developer
    /// builds and tests, otherwise the executable's own directory.
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["JSTI_WHISPER_RUNTIME_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    }

    /// Loads the runtime once. Loading reads DLLs and registers backends, so
    /// call it off the UI thread.
    public static func open(directory: URL = defaultDirectory, allowGPU: Bool) throws -> DesktopNativeWhisperRuntime {
        try open(bridge: .windows, directory: directory, allowGPU: allowGPU)
    }
}
