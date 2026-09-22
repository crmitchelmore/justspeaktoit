import Foundation

/// A runtime family that executes downloaded local models. The set is open: a
/// platform gains a runtime only with its native implementation.
public struct LocalModelRuntime: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// WhisperKit, executing Whisper compiled to Core ML in process.
    public static let whisperKit = LocalModelRuntime(rawValue: "whisperkit")
    /// sherpa-onnx transducer recognisers.
    public static let sherpaOnnx = LocalModelRuntime(rawValue: "sherpa-onnx")
    /// llama.cpp language models.
    public static let llamaCpp = LocalModelRuntime(rawValue: "llama.cpp")
}

/// The on-disk artefact format a runtime loads.
public struct LocalModelArtifactFormat: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let coreML = LocalModelArtifactFormat(rawValue: "coreml")
    public static let onnx = LocalModelArtifactFormat(rawValue: "onnx")
    public static let gguf = LocalModelArtifactFormat(rawValue: "gguf")
}

/// What executing a downloaded model requires: a runtime and the artefact
/// format it loads.
///
/// Portable metadata does not make an artefact portable. Core ML Whisper
/// weights still need a Core ML runtime, even though their catalogue entries
/// compile on every platform.
public struct LocalModelBackend: Hashable, Sendable {
    public let runtime: LocalModelRuntime
    public let artifactFormat: LocalModelArtifactFormat

    public init(runtime: LocalModelRuntime, artifactFormat: LocalModelArtifactFormat) {
        self.runtime = runtime
        self.artifactFormat = artifactFormat
    }

    public static let whisperKitCoreML = LocalModelBackend(runtime: .whisperKit, artifactFormat: .coreML)
    public static let sherpaOnnx = LocalModelBackend(runtime: .sherpaOnnx, artifactFormat: .onnx)
    public static let llamaCppGGUF = LocalModelBackend(runtime: .llamaCpp, artifactFormat: .gguf)
}

/// A downloaded local model and the backend that executes it.
public protocol DownloadedLocalModel {
    /// `nil` when no backend can execute the model.
    var backend: LocalModelBackend? { get }
}

extension LocalTranscriptionModel: DownloadedLocalModel {
    /// WhisperKit entries need Core ML; no other engine has an app runtime.
    public var backend: LocalModelBackend? {
        engine == .whisperKit ? .whisperKitCoreML : nil
    }
}

extension LocalStreamingModelSource: DownloadedLocalModel {}

extension LocalPostProcessingModel: DownloadedLocalModel {}

/// The downloaded-model backends a host has actually implemented.
///
/// Hosts project the shared catalogues through this value, so an entry appears
/// only where both its runtime and its artefact format are implemented. A
/// catalogue listing, an identifier prefix or a decodable record is never a
/// capability claim.
public struct LocalModelHostSupport: Equatable, Sendable {
    public let backends: Set<LocalModelBackend>

    public init(backends: Set<LocalModelBackend>) {
        self.backends = backends
    }

    /// A host with no local runtime.
    public static let unsupported = LocalModelHostSupport(backends: [])

    /// Windows implements no local runtime yet. Add a backend here only with
    /// its native runtime, verified downloads, preparation and measured
    /// CPU/GPU acceptance.
    public static let windows = unsupported

    /// macOS runs WhisperKit's Core ML models in process on every channel.
    /// sherpa-onnx and llama.cpp install or spawn executables, which only
    /// Developer ID builds may do; SpeakApp applies the same rule at compile
    /// time through `APP_STORE`.
    public static func macOS(channel: DistributionChannel) -> LocalModelHostSupport {
        var backends: Set<LocalModelBackend> = []
        if channel.supportsDownloadedCoreMLModels {
            backends.insert(.whisperKitCoreML)
        }
        if channel.supportsExternalLocalModelRuntime {
            backends.insert(.sherpaOnnx)
            backends.insert(.llamaCppGGUF)
        }
        return LocalModelHostSupport(backends: backends)
    }

    public func canExecute(_ backend: LocalModelBackend?) -> Bool {
        guard let backend else { return false }
        return backends.contains(backend)
    }

    /// The entries of `models` this host can execute, in their original order.
    public func executableModels<Model: DownloadedLocalModel>(in models: [Model]) -> [Model] {
        models.filter { canExecute($0.backend) }
    }
}
