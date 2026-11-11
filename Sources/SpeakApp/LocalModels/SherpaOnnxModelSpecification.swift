import Foundation
import SpeakCore

#if !APP_STORE
enum SherpaOnnxRuntimeError: LocalizedError {
  case pythonUnavailable
  case runtimeUnavailable(String)
  case unsupportedModel(String)
  case downloadFailed(String)
  case processFailed(String)
  case runtimeUpdateRequired(installed: String, required: String)

  var errorDescription: String? {
    switch self {
    case .pythonUnavailable:
      return "Python 3 was not found. Install Python 3 to enable experimental sherpa-onnx local streaming."
    case .runtimeUnavailable(let details):
      return "sherpa-onnx is not installed for Python 3. \(details)"
    case .unsupportedModel(let model):
      return "\(model) is not a supported sherpa-onnx streaming model in this prerelease."
    case .downloadFailed(let details):
      return "Could not download the sherpa-onnx model files. \(details)"
    case .processFailed(let details):
      return "sherpa-onnx failed to start. \(details)"
    case .runtimeUpdateRequired(let installed, let required):
      return "This model needs sherpa-onnx \(required) or later, but \(installed) is installed. "
        + "Choose Update Runtime in Local Streaming settings."
    }
  }
}

struct SherpaOnnxModelBundle: Equatable, Sendable {
  let source: LocalStreamingModelSource
  let directory: URL
  let tokens: URL
  let encoder: URL
  let decoder: URL
  let joiner: URL
  let featureDim: Int
  /// sherpa-onnx model type: "transducer" runs the online recognizer;
  /// "nemo_transducer" runs the offline recognizer (e.g. NVIDIA Parakeet TDT).
  let modelType: String
  /// Whether the sidecar may pass a per-stream language prompt.
  var supportsLanguageHint = false
}

/// The files, feature size and runtime requirements of one supported
/// sherpa-onnx export, keyed off the model source's repository and name.
struct SherpaOnnxModelSpecification {
  let tokens: String
  let encoder: String
  let decoder: String
  let joiner: String
  var featureDim: Int = 80
  var archiveURL: URL?
  /// "transducer" (online recognizer) unless the model is an offline NeMo
  /// transducer such as Parakeet TDT ("nemo_transducer").
  var modelType: String = "transducer"
  /// Pinned archive checksum, verified after download when present.
  var archiveSHA256: String?
  /// Oldest sherpa-onnx release known to decode this export.
  var minimumRuntimeVersion: String?
  /// Language-ID prompted models accept a per-stream language option.
  var supportsLanguageHint = false

  var files: [String] { [tokens, encoder, decoder, joiner] }

  static func resolve(for source: LocalStreamingModelSource) throws -> SherpaOnnxModelSpecification {
    if let nvidia = parakeetSpecification(for: source) ?? multilingualNemotronSpecification(for: source) {
      return nvidia
    }
    let repo = source.repoID.lowercased()
    if repo.contains("en-20m-2023-02-17") {
      return SherpaOnnxModelSpecification(
        tokens: "tokens.txt",
        encoder: "encoder-epoch-99-avg-1.int8.onnx",
        decoder: "decoder-epoch-99-avg-1.int8.onnx",
        joiner: "joiner-epoch-99-avg-1.int8.onnx"
      )
    }
    if repo.contains("en-kroko-2025-08-06") {
      return SherpaOnnxModelSpecification(
        tokens: "tokens.txt",
        encoder: "encoder.onnx",
        decoder: "decoder.onnx",
        joiner: "joiner.onnx"
      )
    }
    if repo.contains("nemotron-speech-streaming-en-0.6b")
      || source.modelName.lowercased().contains("nemotron-speech-streaming-en-0.6b") {
      let root = source.modelName
      return SherpaOnnxModelSpecification(
        tokens: "\(root)/tokens.txt",
        encoder: "\(root)/encoder.int8.onnx",
        decoder: "\(root)/decoder.int8.onnx",
        joiner: "\(root)/joiner.int8.onnx",
        featureDim: 128,
        archiveURL: source.archiveURL
      )
    }
    if repo.contains("en-2023-06-21") {
      return SherpaOnnxModelSpecification(
        tokens: "tokens.txt",
        encoder: "encoder-epoch-99-avg-1.int8.onnx",
        decoder: "decoder-epoch-99-avg-1.onnx",
        joiner: "joiner-epoch-99-avg-1.int8.onnx"
      )
    }
    if repo.contains("en-2023-06-26") {
      return SherpaOnnxModelSpecification(
        tokens: "tokens.txt",
        encoder: "encoder-epoch-99-avg-1-chunk-16-left-64.int8.onnx",
        decoder: "decoder-epoch-99-avg-1-chunk-16-left-64.int8.onnx",
        joiner: "joiner-epoch-99-avg-1-chunk-16-left-64.int8.onnx"
      )
    }
    throw SherpaOnnxRuntimeError.unsupportedModel(source.displayName)
  }

  /// NVIDIA Nemotron 3.5: multilingual cache-aware transducer. Needs the pinned
  /// runtime that added it and honours an explicit language hint.
  private static func multilingualNemotronSpecification(
    for source: LocalStreamingModelSource
  ) -> SherpaOnnxModelSpecification? {
    guard NemotronLocalModels.isMultilingual("\(source.repoID) \(source.modelName)") else { return nil }
    let root = source.modelName
    let variant = NemotronLocalModels.variant(named: root)
    return SherpaOnnxModelSpecification(
      tokens: "\(root)/tokens.txt",
      encoder: "\(root)/encoder.int8.onnx",
      decoder: "\(root)/decoder.int8.onnx",
      joiner: "\(root)/joiner.int8.onnx",
      featureDim: 128,
      archiveURL: source.archiveURL ?? variant?.archiveURL,
      archiveSHA256: variant?.archiveSHA256,
      minimumRuntimeVersion: NemotronLocalModels.minimumRuntimeVersion,
      supportsLanguageHint: true
    )
  }

  /// NVIDIA Parakeet v3: offline NeMo TDT transducer. Decoded by the offline
  /// recognizer (model_type "nemo_transducer", greedy search) with the 128-dim
  /// mel features the NeMo export was trained on.
  private static func parakeetSpecification(
    for source: LocalStreamingModelSource
  ) -> SherpaOnnxModelSpecification? {
    let searchText = "\(source.repoID) \(source.modelName)".lowercased()
    guard searchText.contains("nemo-parakeet-tdt-0.6b-v3") else { return nil }
    let root = source.modelName
    return SherpaOnnxModelSpecification(
      tokens: "\(root)/tokens.txt",
      encoder: "\(root)/encoder.int8.onnx",
      decoder: "\(root)/decoder.int8.onnx",
      joiner: "\(root)/joiner.int8.onnx",
      featureDim: 128,
      archiveURL: source.archiveURL ?? ParakeetLocalModels.tdtV3Int8ArchiveURL,
      modelType: "nemo_transducer",
      archiveSHA256: ParakeetLocalModels.tdtV3Int8ArchiveSHA256
    )
  }
}

#endif
