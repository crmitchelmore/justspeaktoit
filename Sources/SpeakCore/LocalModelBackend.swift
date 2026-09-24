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
    /// whisper.cpp, executing Whisper as GGML weights in process on the CPU or
    /// through a GPU backend such as Vulkan.
    public static let whisperCpp = LocalModelRuntime(rawValue: "whisper.cpp")
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
    /// whisper.cpp's single-file GGML model format (`ggml-*.bin`).
    public static let ggml = LocalModelArtifactFormat(rawValue: "ggml")
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
    public static let whisperCppGGML = LocalModelBackend(runtime: .whisperCpp, artifactFormat: .ggml)
}

/// A downloaded local model and the backends that can execute it.
public protocol DownloadedLocalModel {
    /// The primary backend; `nil` when no backend can execute the model.
    var backend: LocalModelBackend? { get }
    /// Every backend with a qualified artefact for this model. Most entries
    /// have exactly one; a catalogue Whisper entry also has pinned GGML
    /// weights for whisper.cpp. Defaults to `backend`.
    var backends: Set<LocalModelBackend> { get }
}

public extension DownloadedLocalModel {
    var backends: Set<LocalModelBackend> {
        backend.map { [$0] } ?? []
    }
}

extension LocalTranscriptionModel: DownloadedLocalModel {
    /// WhisperKit entries need Core ML; no other engine has an app runtime.
    public var backend: LocalModelBackend? {
        engine == .whisperKit ? .whisperKitCoreML : nil
    }

    /// Core ML for every WhisperKit entry, plus whisper.cpp for a catalogue
    /// entry that `WhisperCppModels` pins to verified GGML weights. Imported
    /// Core ML models never gain a whisper.cpp route by sharing a name.
    public var backends: Set<LocalModelBackend> {
        var result: Set<LocalModelBackend> = backend.map { [$0] } ?? []
        if engine == .whisperKit, WhisperCppModels.model(forCatalogueID: id) != nil {
            result.insert(.whisperCppGGML)
        }
        return result
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

    /// Windows runs pinned GGML Whisper weights through the bundled
    /// whisper.cpp runtime (Vulkan when a driver provides it, otherwise the
    /// CPU). Only catalogue entries `WhisperCppModels` qualifies project into
    /// it; sherpa-onnx, llama.cpp and Core ML artefacts stay unavailable.
    /// Whether the runtime DLLs are present is a separate runtime check.
    public static let windows = LocalModelHostSupport(backends: [.whisperCppGGML])

    /// Linux runs the same pinned GGML Whisper weights through a whisper.cpp
    /// runtime built from the same pin and loaded from beside the executable
    /// (the CPU, or Vulkan when the runtime was built with it). It therefore
    /// projects exactly the entries Windows does; whether the libraries are
    /// present is a separate runtime check.
    public static let linux = LocalModelHostSupport(backends: [.whisperCppGGML])

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

    /// Whether any qualified artefact of `model` runs on this host.
    public func canExecute<Model: DownloadedLocalModel>(model: Model) -> Bool {
        !backends.isDisjoint(with: model.backends)
    }

    /// The backend this host uses for `model`: the model's primary backend
    /// when the host runs it, otherwise another qualified one.
    public func preferredBackend<Model: DownloadedLocalModel>(for model: Model) -> LocalModelBackend? {
        if let primary = model.backend, backends.contains(primary) { return primary }
        return model.backends.intersection(backends).sorted { $0.runtime.rawValue < $1.runtime.rawValue }.first
    }

    /// The entries of `models` this host can execute, in their original order.
    public func executableModels<Model: DownloadedLocalModel>(in models: [Model]) -> [Model] {
        models.filter { canExecute(model: $0) }
    }
}
