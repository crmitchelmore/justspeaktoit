import Foundation

/// Canonical downloadable local-model catalogues, beside `localTranscription`
/// (WhisperKit Core ML batch and live models) in `ModelCatalog.swift`.
///
/// Listing an entry is not a capability claim. Each entry declares the backend
/// that executes it, and a host exposes only what
/// `LocalModelHostSupport.executableModels(in:)` admits. Every entry here needs
/// an installable runtime (sherpa-onnx or llama.cpp): macOS offers them only in
/// Developer ID builds, and no Windows local runtime exists yet.
public extension ModelCatalog {
    /// Downloadable sherpa-onnx streaming sources: Parakeet v3 first, then
    /// Nemotron, then lightweight Zipformer models. WhisperKit live models come
    /// from `localTranscription`.
    static let localStreamingSources: [LocalStreamingModelSource] = [
        LocalStreamingModelSource(
            repoID: ParakeetLocalModels.tdtV3Int8RepoID,
            modelName: ParakeetLocalModels.tdtV3Int8ModelName,
            runtime: "sherpa-onnx streaming runtime",
            approximateSizeMB: ParakeetLocalModels.tdtV3Int8DownloadSizeMB,
            archiveURL: ParakeetLocalModels.tdtV3Int8ArchiveURL
        ),
        LocalStreamingModelSource(
            repoID: "k2-fsa/sherpa-onnx",
            modelName: "sherpa-onnx-nemotron-speech-streaming-en-0.6b-1120ms-int8-2026-04-25",
            runtime: "sherpa-onnx streaming runtime",
            approximateSizeMB: 632,
            archiveURL: URL(
                string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
                    + "sherpa-onnx-nemotron-speech-streaming-en-0.6b-1120ms-int8-2026-04-25.tar.bz2"
            )
        ),
        LocalStreamingModelSource(
            repoID: "k2-fsa/sherpa-onnx",
            modelName: "sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25",
            runtime: "sherpa-onnx streaming runtime",
            approximateSizeMB: 632,
            archiveURL: URL(
                string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
                    + "sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25.tar.bz2"
            )
        ),
        LocalStreamingModelSource(
            repoID: "csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06",
            modelName: "streaming-zipformer-en-kroko-2025-08-06",
            runtime: "sherpa-onnx streaming runtime",
            approximateSizeMB: 71
        ),
        LocalStreamingModelSource(
            repoID: "csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-21",
            modelName: "streaming-zipformer-en-2023-06-21",
            runtime: "sherpa-onnx streaming runtime",
            approximateSizeMB: 181
        ),
        LocalStreamingModelSource(
            repoID: "csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26",
            modelName: "streaming-zipformer-en-2023-06-26",
            runtime: "sherpa-onnx streaming runtime",
            approximateSizeMB: 73
        ),
        LocalStreamingModelSource(
            repoID: "csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17",
            modelName: "streaming-zipformer-en-20M-2023-02-17",
            runtime: "sherpa-onnx streaming runtime",
            approximateSizeMB: 44
        )
    ]

    /// Downloadable GGUF cleanup models, in presentation order. Built-in rules
    /// cleanup stays in `postProcessing`.
    static let localPostProcessing: [LocalPostProcessingModel] = [
        LocalPostProcessingModel(
            id: "local/post-processing/qwen3-1.7b-q4",
            displayName: "Qwen3 1.7B Q4",
            repoID: "unsloth/Qwen3-1.7B-GGUF",
            filename: "Qwen3-1.7B-Q4_K_M.gguf",
            approximateSizeMB: 1_100,
            description: "Recommended tiny local LLM for higher-quality cleanup. "
                + "Current Qwen3 family, stronger instructions."
        ),
        LocalPostProcessingModel(
            id: "local/post-processing/qwen3-0.6b-q4",
            displayName: "Qwen3 0.6B Q4",
            repoID: "unsloth/Qwen3-0.6B-GGUF",
            filename: "Qwen3-0.6B-Q4_K_M.gguf",
            approximateSizeMB: 450,
            description: "Fastest current Qwen3 tiny local model. Good for quick simple cleanup on-device."
        ),
        LocalPostProcessingModel(
            id: "local/post-processing/smollm2-360m-instruct-q4",
            displayName: "SmolLM2 360M Instruct Q4",
            repoID: "bartowski/SmolLM2-360M-Instruct-GGUF",
            filename: "SmolLM2-360M-Instruct-Q4_K_M.gguf",
            approximateSizeMB: 230,
            description: "Smallest recommended download. Best for quick cleanup, "
                + "with lower quality on complex transcripts."
        )
    ]
}
