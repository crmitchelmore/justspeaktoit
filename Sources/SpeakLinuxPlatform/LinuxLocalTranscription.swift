import Foundation
import SpeakCore
import SpeakDesktop
import CLinuxSupport

public typealias LinuxLocalTranscriptionError = DesktopNativeLocalTranscriptionError
public typealias LinuxSHA256Hasher = DesktopNativeSHA256Hasher
public typealias LinuxWhisperRuntime = DesktopNativeWhisperRuntime
public typealias LinuxWhisperRecognizer = DesktopNativeWhisperRecognizer

extension DesktopNativeLocalTranscriptionBridge {
    /// GLib's GChecksum SHA-256 and the whisper.cpp runtime installed beside the executable.
    public static let linux = DesktopNativeLocalTranscriptionBridge(
        sha256Create: jsti_sha256_create, sha256Update: jsti_sha256_update, sha256Finish: jsti_sha256_finish,
        sha256Destroy: jsti_sha256_destroy, runtimeOpen: jsti_whisper_runtime_open,
        runtimeDescribe: jsti_whisper_runtime_describe, runtimeUsesGPU: jsti_whisper_runtime_uses_gpu,
        releaseModel: jsti_whisper_runtime_release_model, releaseModelAt: jsti_whisper_runtime_release_model_at,
        jobCreate: jsti_whisper_job_create, jobCancel: jsti_whisper_job_cancel, jobDestroy: jsti_whisper_job_destroy,
        transcribe: jsti_whisper_transcribe, freeText: jsti_whisper_free_text, digestName: "GLib GChecksum SHA-256"
    )
}

extension DesktopNativeSHA256Hasher {
    public convenience init() throws { try self.init(bridge: .linux) }

    public static var provider: LocalModelDigestProvider { digestProvider(.linux) }
}

extension DesktopNativeWhisperRuntime {
    /// The library directory: `JSTI_WHISPER_RUNTIME_DIRECTORY` for developer
    /// builds and tests, otherwise the executable's own directory (where the
    /// Flatpak also keeps the SwiftPM resource bundles).
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["JSTI_WHISPER_RUNTIME_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let executable = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath()
        return executable.deletingLastPathComponent()
    }

    /// The runtime's main library, whose presence means the runtime is installed.
    public static let libraryName = "libwhisper.so.1"
    /// Present only in runtimes built with the optional Vulkan backend.
    public static let vulkanBackendName = "libggml-vulkan.so"

    /// Loads the runtime once. Loading reads libraries and registers backends,
    /// so call it off the UI thread.
    public static func open(directory: URL = defaultDirectory, allowGPU: Bool) throws -> DesktopNativeWhisperRuntime {
        try open(bridge: .linux, directory: directory, allowGPU: allowGPU)
    }
}
