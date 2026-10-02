import Foundation

/// A downloadable streaming speech-recognition source, identified as
/// `local/streaming/huggingface/<repo>/<model>`.
///
/// The Codable form is persisted in `streaming-model-sources.json` and
/// data-migration archives; keep its field names. A decoded `id` is kept
/// verbatim, and `normalized(_:)` re-derives runtime and size metadata on load.
/// `runtime` is persisted display text, not an execution capability: `backend`
/// is the typed requirement a host must implement.
public struct LocalStreamingModelSource: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let repoID: String
    public let modelName: String
    public let runtime: String
    public let approximateSizeMB: Int?
    public let archiveURL: URL?

    public init(
        repoID: String,
        modelName: String,
        runtime: String? = nil,
        approximateSizeMB: Int? = nil,
        archiveURL: URL? = nil
    ) {
        let repoID = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = LocalModelIdentity.streamingSourceID(repoID: repoID, modelName: modelName)
        self.repoID = repoID
        self.modelName = modelName
        self.runtime = runtime ?? Self.runtimeHint(repoID: repoID, modelName: modelName)
        self.approximateSizeMB = approximateSizeMB
            ?? Self.knownApproximateSizeMB(repoID: repoID, modelName: modelName)
        self.archiveURL = archiveURL
    }

    public var displayName: String {
        "\(modelName) from \(repoID)"
    }

    /// sherpa-onnx for sources `isRunnableSherpaOnnxSource(_:)` admits;
    /// `nil` for anything no backend can run.
    public var backend: LocalModelBackend? {
        Self.isRunnableSherpaOnnxSource(self) ? .sherpaOnnx : nil
    }
}

public extension LocalStreamingModelSource {
    static let sherpaOnnxRuntimeHint = "sherpa-onnx streaming runtime"
    static let whisperCppRuntimeHint = "whisper.cpp streaming runtime"
    static let genericRuntimeHint = "Streaming ASR runtime"

    /// The display text persisted in `runtime`, derived from the source identity.
    static func runtimeHint(repoID: String, modelName: String) -> String {
        let searchText = "\(repoID) \(modelName)".lowercased()
        if searchText.contains("sherpa") || searchText.contains("zipformer") || searchText.contains("onnx") {
            return sherpaOnnxRuntimeHint
        }
        if searchText.contains("whisper.cpp") || searchText.contains("ggml") || searchText.contains("gguf") {
            return whisperCppRuntimeHint
        }
        return genericRuntimeHint
    }

    /// Download size for known source families, backfilled when a source
    /// arrives without one.
    static func knownApproximateSizeMB(repoID: String, modelName: String) -> Int? {
        let searchText = "\(repoID) \(modelName)".lowercased()
        if searchText.contains("parakeet-tdt-0.6b-v3") {
            return ParakeetLocalModels.tdtV3Int8DownloadSizeMB
        }
        if searchText.contains("en-kroko-2025-08-06") {
            return 71
        }
        if searchText.contains("nemotron-speech-streaming-en-0.6b") {
            return 632
        }
        if searchText.contains("en-2023-06-21") {
            return 181
        }
        if searchText.contains("en-20m-2023-02-17") {
            return 44
        }
        if searchText.contains("en-2023-06-26") {
            return 73
        }
        return nil
    }

    /// Admits only runnable sherpa-onnx exports; loading drops persisted
    /// sources this rejects. Raw NeMo checkpoints from `nvidia/*` repositories
    /// are not runnable, and Parakeet is admitted solely as the sherpa-onnx
    /// `nemo-parakeet-tdt-0.6b-v3` conversion. The persisted `runtime` text
    /// takes part, exactly as it always has.
    static func isRunnableSherpaOnnxSource(_ source: LocalStreamingModelSource) -> Bool {
        let text = "\(source.id) \(source.repoID) \(source.modelName) \(source.runtime)".lowercased()
        guard text.contains("sherpa"), !text.contains("nvidia") else { return false }
        let isNemotron = text.contains("nemotron")
        let isSherpaParakeetV3 = text.contains("nemo-parakeet-tdt-0.6b-v3")
        guard isNemotron || isSherpaParakeetV3 || !text.contains("nemo") else { return false }
        return text.contains("zipformer") || isNemotron || isSherpaParakeetV3
    }

    /// Re-derives the identifier and runtime text, backfills a known size and
    /// keeps the persisted archive URL.
    static func normalized(_ source: LocalStreamingModelSource) -> LocalStreamingModelSource {
        LocalStreamingModelSource(
            repoID: source.repoID,
            modelName: source.modelName,
            runtime: runtimeHint(repoID: source.repoID, modelName: source.modelName),
            approximateSizeMB: source.approximateSizeMB
                ?? knownApproximateSizeMB(repoID: source.repoID, modelName: source.modelName),
            archiveURL: source.archiveURL
        )
    }
}
