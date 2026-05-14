import Foundation
import OSLog
import SpeakCore
import class WhisperKit.WhisperKit
import class WhisperKit.WhisperKitConfig

enum LocalModelError: LocalizedError {
  case unknownModel(String)
  case notInstalled(String)
  case emptyTranscript(String)
  case invalidHuggingFaceRepo(String)
  case invalidHuggingFaceModel

  var errorDescription: String? {
    switch self {
    case .unknownModel(let model):
      return "Unknown local model: \(model)"
    case .notInstalled(let model):
      return "\(model) has not been downloaded yet. Download it in Settings > Transcription > Local Models."
    case .emptyTranscript(let model):
      return "\(model) produced an empty transcript."
    case .invalidHuggingFaceRepo(let repo):
      return "\(repo) is not a valid Hugging Face repo ID. Use owner/repo, for example argmaxinc/whisperkit-coreml."
    case .invalidHuggingFaceModel:
      return """
      Enter a supported local model name. Local Batch expects a WhisperKit variant; \
      Local Streaming expects a sherpa-onnx Zipformer source.
      """
    }
  }
}

@MainActor
final class LocalModelManager: ObservableObject {
  static let shared = LocalModelManager()

  enum InstallState: Equatable {
    case notInstalled
    case installing
    case installed
    case failed(String)
  }

  @Published private(set) var installStates: [String: InstallState] = [:]
  @Published private(set) var importedModels: [LocalTranscriptionModel] = []
  @Published private(set) var streamingModelSources: [LocalStreamingModelSource] = []

  static let recommendedStreamingModelSources: [LocalStreamingModelSource] = [
    LocalStreamingModelSource(
      repoID: "csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06",
      modelName: "streaming-zipformer-en-kroko-2025-08-06",
      runtime: "sherpa-onnx streaming runtime",
      approximateSizeMB: 71
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
    ),
  ]

  private var activePipelines: [String: WhisperKit] = [:]
  private let fileManager: FileManager
  private let logger = Logger(subsystem: "com.github.speakapp", category: "LocalModelManager")
  private let markerDirectory: URL
  private let importedModelsURL: URL
  private let streamingModelSourcesURL: URL
  private var storageError: Error?

  private init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
    markerDirectory = base
      .appendingPathComponent("SpeakApp", isDirectory: true)
      .appendingPathComponent("LocalModels", isDirectory: true)
    importedModelsURL = markerDirectory.appendingPathComponent("imported-hugging-face-models.json")
    streamingModelSourcesURL = markerDirectory.appendingPathComponent("streaming-model-sources.json")
    do {
      try fileManager.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
    } catch {
      storageError = error
      logger.error("Failed to prepare local model storage: \(error.localizedDescription, privacy: .public)")
    }
    loadImportedModels()
    loadStreamingModelSources()
    refreshInstallStates()
  }

  var availableModels: [LocalTranscriptionModel] {
    ModelCatalog.localTranscription + importedModels
  }

  var availableModelOptions: [ModelCatalog.Option] {
    availableModels.map(\.option)
  }

  func refreshInstallStates() {
    if let storageError {
      for model in availableModels {
        installStates[model.id] = .failed(storageError.localizedDescription)
      }
      return
    }
    for model in availableModels {
      installStates[model.id] = markerExists(for: model) ? .installed : .notInstalled
    }
  }

  func installState(for modelID: String) -> InstallState {
    installStates[modelID] ?? .notInstalled
  }

  func isInstalled(_ modelID: String) -> Bool {
    installState(for: modelID) == .installed
  }

  func isModelLoaded(_ modelID: String) -> Bool {
    activePipelines[modelID] != nil
  }

  func model(for modelID: String) -> LocalTranscriptionModel? {
    availableModels.first { $0.id == modelID }
  }

  @discardableResult
  func importHuggingFaceModel(repoID: String, modelName: String) throws -> LocalTranscriptionModel {
    let repoID = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
    let modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard repoID.split(separator: "/").count == 2 else {
      throw LocalModelError.invalidHuggingFaceRepo(repoID)
    }
    guard !modelName.isEmpty else {
      throw LocalModelError.invalidHuggingFaceModel
    }
    let resolvedModel = Self.resolveHuggingFaceModel(repoID: repoID, modelName: modelName)

    let model = LocalTranscriptionModel(
      id: Self.huggingFaceModelID(repoID: repoID, modelName: resolvedModel.modelName),
      displayName: "\(resolvedModel.displayName) from \(repoID)",
      modelName: resolvedModel.modelName,
      engine: "whisperkit",
      modelRepo: repoID,
      approximateSizeMB: resolvedModel.approximateSizeMB,
      description: """
      Imported from Hugging Face. WhisperKit will download the matching Core ML files from \(repoID).
      """,
      tags: [.quality]
    )

    importedModels.removeAll {
      $0.id == model.id || ($0.modelRepo == model.modelRepo && $0.modelName == model.modelName)
    }
    importedModels.append(model)
    try saveImportedModels()
    installStates[model.id] = markerExists(for: model) ? .installed : .notInstalled
    return model
  }

  @discardableResult
  func addStreamingModelSource(repoID: String, modelName: String) throws -> LocalStreamingModelSource {
    let repoID = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
    let modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard repoID.split(separator: "/").count == 2 else {
      throw LocalModelError.invalidHuggingFaceRepo(repoID)
    }
    guard !modelName.isEmpty else {
      throw LocalModelError.invalidHuggingFaceModel
    }

    let source = LocalStreamingModelSource(repoID: repoID, modelName: modelName)
    guard Self.isSupportedStreamingSource(source) else {
      throw LocalModelError.invalidHuggingFaceModel
    }
    try addStreamingModelSource(source)
    return source
  }

  @discardableResult
  func addStreamingModelSource(_ source: LocalStreamingModelSource) throws -> LocalStreamingModelSource {
    streamingModelSources.removeAll { $0.id == source.id }
    streamingModelSources.append(source)
    try saveStreamingModelSources()
    return source
  }

  func deleteStreamingModelSource(_ source: LocalStreamingModelSource) {
    streamingModelSources.removeAll { $0.id == source.id }
    do {
      try saveStreamingModelSources()
    } catch {
      logger.error("Failed to save local streaming model sources: \(error.localizedDescription, privacy: .public)")
    }
  }

  func install(_ model: LocalTranscriptionModel) async {
    installStates[model.id] = .installing
    do {
      _ = try await pipeline(for: model)
      try Data("installed\n".utf8).write(to: markerURL(for: model), options: .atomic)
      installStates[model.id] = .installed
    } catch {
      installStates[model.id] = .failed(error.localizedDescription)
    }
  }

  func delete(_ model: LocalTranscriptionModel) {
    activePipelines[model.id] = nil
    do {
      let markerURL = markerURL(for: model)
      if fileManager.fileExists(atPath: markerURL.path) {
        try fileManager.removeItem(at: markerURL)
      }
      installStates[model.id] = .notInstalled
    } catch {
      installStates[model.id] = .failed(error.localizedDescription)
      logger.error("Failed to remove local model marker: \(error.localizedDescription, privacy: .public)")
    }
  }

  func transcribeFile(at url: URL, modelID: String, language: String?) async throws -> TranscriptionResult {
    guard let model = model(for: modelID) else {
      throw LocalModelError.unknownModel(modelID)
    }
    guard isInstalled(model.id) else {
      throw LocalModelError.notInstalled(model.displayName)
    }

    let start = Date()
    let pipe = try await pipeline(for: model)
    let whisperResults = try await pipe.transcribe(audioPath: url.path)
    let text = cleanTranscriptText(
      whisperResults
      .map(\.text)
      .joined(separator: " ")
    )
    guard !text.isEmpty else {
      throw LocalModelError.emptyTranscript(model.displayName)
    }

    return TranscriptionResult(
      text: text,
      segments: [],
      confidence: nil,
      duration: Date().timeIntervalSince(start),
      modelIdentifier: model.id,
      cost: nil,
      rawPayload: nil,
      debugInfo: nil
    )
  }

  private func pipeline(for model: LocalTranscriptionModel) async throws -> WhisperKit {
    if let existing = activePipelines[model.id] {
      return existing
    }
    let config = WhisperKitConfig(
      model: model.modelName,
      modelRepo: model.modelRepo,
      verbose: false,
      load: true
    )
    let pipe = try await WhisperKit(config)
    activePipelines[model.id] = pipe
    return pipe
  }

  private func cleanTranscriptText(_ text: String) -> String {
    text
      .replacingOccurrences(of: "[BLANK_AUDIO]", with: "", options: .caseInsensitive)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func markerExists(for model: LocalTranscriptionModel) -> Bool {
    fileManager.fileExists(atPath: markerURL(for: model).path)
  }

  private func markerURL(for model: LocalTranscriptionModel) -> URL {
    markerDirectory.appendingPathComponent(model.id.replacingOccurrences(of: "/", with: "_") + ".installed")
  }

  private func loadImportedModels() {
    guard fileManager.fileExists(atPath: importedModelsURL.path) else { return }
    do {
      let data = try Data(contentsOf: importedModelsURL)
      let records = try JSONDecoder().decode([ImportedModelRecord].self, from: data)
      var didMigrate = false
      let migratedModels = records.map { record in
        let model = record.model
        let resolved = Self.resolveHuggingFaceModel(
          repoID: model.modelRepo ?? "",
          modelName: model.modelName
        )
        guard resolved.modelName != model.modelName || model.approximateSizeMB <= 0 else { return model }
        didMigrate = true
        let repoID = model.modelRepo ?? "Hugging Face"
        return LocalTranscriptionModel(
          id: Self.huggingFaceModelID(repoID: repoID, modelName: resolved.modelName),
          displayName: "\(resolved.displayName) from \(repoID)",
          modelName: resolved.modelName,
          engine: model.engine,
          modelRepo: model.modelRepo,
          approximateSizeMB: resolved.approximateSizeMB,
          description: model.description,
          tags: model.tags,
          supportsLiveStreaming: model.supportsLiveStreaming
        )
      }
      importedModels = Self.deduplicateModels(migratedModels)
      if didMigrate {
        try? saveImportedModels()
      }
    } catch {
      logger.error("Failed to load imported Hugging Face models: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func loadStreamingModelSources() {
    guard fileManager.fileExists(atPath: streamingModelSourcesURL.path) else { return }
    do {
      let data = try Data(contentsOf: streamingModelSourcesURL)
      let decoded = try JSONDecoder().decode([LocalStreamingModelSource].self, from: data)
      streamingModelSources = decoded.filter(Self.isSupportedStreamingSource)
      if streamingModelSources.count != decoded.count {
        try? saveStreamingModelSources()
      }
    } catch {
      logger.error("Failed to load local streaming model sources: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func saveImportedModels() throws {
    let records = importedModels.map(ImportedModelRecord.init(model:))
    let data = try JSONEncoder().encode(records)
    try data.write(to: importedModelsURL, options: .atomic)
  }

  private func saveStreamingModelSources() throws {
    let data = try JSONEncoder().encode(streamingModelSources)
    try data.write(to: streamingModelSourcesURL, options: .atomic)
  }

  nonisolated static func huggingFaceModelID(repoID: String, modelName: String) -> String {
    "local/whisperkit/huggingface/\(slug(repoID))/\(slug(modelName))"
  }

  nonisolated static func slug(_ value: String) -> String {
    value
      .lowercased()
      .map { character in
        character.isLetter || character.isNumber || character == "-" || character == "/" ? character : "-"
      }
      .reduce(into: "") { result, character in result.append(character) }
  }

  private nonisolated static func deduplicateModels(_ models: [LocalTranscriptionModel]) -> [LocalTranscriptionModel] {
    var seenIDs = Set<String>()
    return models.reversed().compactMap { model in
      guard !seenIDs.contains(model.id) else { return nil }
      seenIDs.insert(model.id)
      return model
    }.reversed()
  }

  nonisolated static func streamingRuntimeHint(for repoID: String, modelName: String) -> String {
    let searchText = "\(repoID) \(modelName)".lowercased()
    if searchText.contains("sherpa") || searchText.contains("zipformer") || searchText.contains("onnx") {
      return "sherpa-onnx streaming runtime"
    }
    if searchText.contains("whisper.cpp") || searchText.contains("ggml") || searchText.contains("gguf") {
      return "whisper.cpp streaming runtime"
    }
    return "Streaming ASR runtime"
  }

  nonisolated static func streamingApproximateSizeMB(repoID: String, modelName: String) -> Int? {
    let searchText = "\(repoID) \(modelName)".lowercased()
    if searchText.contains("en-kroko-2025-08-06") {
      return 71
    }
    if searchText.contains("en-20m-2023-02-17") {
      return 44
    }
    if searchText.contains("en-2023-06-26") {
      return 73
    }
    return nil
  }

  nonisolated static func isSupportedStreamingSource(_ source: LocalStreamingModelSource) -> Bool {
    let text = "\(source.id) \(source.repoID) \(source.modelName) \(source.runtime)".lowercased()
    guard !text.contains("parakeet"), !text.contains("nemo"), !text.contains("nvidia") else {
      return false
    }
    return text.contains("sherpa") && text.contains("zipformer")
  }

  nonisolated static func resolveHuggingFaceModel(repoID: String, modelName: String) -> ResolvedHuggingFaceModel {
    let repo = repoID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let trimmedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard repo == "argmaxinc/whisperkit-coreml" else {
      return ResolvedHuggingFaceModel(
        modelName: trimmedName,
        displayName: trimmedName,
        approximateSizeMB: sizeFromModelName(trimmedName) ?? 0
      )
    }

    let lookupKey = trimmedName.lowercased()
    if let known = knownArgmaxWhisperKitModels[lookupKey] {
      return known
    }
    return ResolvedHuggingFaceModel(
      modelName: trimmedName,
      displayName: trimmedName,
      approximateSizeMB: sizeFromModelName(trimmedName) ?? 0
    )
  }

  private nonisolated static func sizeFromModelName(_ modelName: String) -> Int? {
    let suffix = modelName.split(separator: "_").last.map(String.init) ?? ""
    guard suffix.lowercased().hasSuffix("mb") else { return nil }
    return Int(suffix.dropLast(2))
  }

  private nonisolated static let knownArgmaxWhisperKitModels: [String: ResolvedHuggingFaceModel] = {
    func model(
      _ aliases: [String],
      name: String,
      displayName: String,
      size: Int
    ) -> [(String, ResolvedHuggingFaceModel)] {
      aliases.map {
        (
          $0,
          ResolvedHuggingFaceModel(modelName: name, displayName: displayName, approximateSizeMB: size)
        )
      }
    }

    let models = [
      model(
        ["tiny", "whisper-tiny", "openai_whisper-tiny"],
        name: "openai_whisper-tiny",
        displayName: "Whisper Tiny",
        size: 75
      ),
      model(
        ["base", "whisper-base", "openai_whisper-base"],
        name: "openai_whisper-base",
        displayName: "Whisper Base",
        size: 145
      ),
      model(
        ["small", "whisper-small", "openai_whisper-small", "openai_whisper-small_216mb"],
        name: "openai_whisper-small_216MB",
        displayName: "Whisper Small",
        size: 216
      ),
      model(
        ["distil-large-v3", "distil-whisper_distil-large-v3", "distil-whisper_distil-large-v3_594mb"],
        name: "distil-whisper_distil-large-v3_594MB",
        displayName: "Distil-Whisper Large v3",
        size: 594
      ),
      model(
        [
          "distil-large-v3-turbo",
          "distil-large-v3_turbo",
          "distil-whisper_distil-large-v3_turbo",
          "distil-whisper_distil-large-v3_turbo_600mb"
        ],
        name: "distil-whisper_distil-large-v3_turbo_600MB",
        displayName: "Distil-Whisper Large v3 Turbo",
        size: 600
      ),
      model(
        [
          "large-v3-turbo",
          "large-v3_turbo",
          "openai_whisper-large-v3-v20240930_turbo",
          "openai_whisper-large-v3-v20240930_turbo_632mb"
        ],
        name: "openai_whisper-large-v3-v20240930_turbo_632MB",
        displayName: "Whisper Large v3 Turbo",
        size: 632
      ),
      model(
        ["openai_whisper-large-v3_turbo", "openai_whisper-large-v3_turbo_954mb"],
        name: "openai_whisper-large-v3_turbo_954MB",
        displayName: "Whisper Large v3 Turbo",
        size: 954
      ),
    ].flatMap { $0 }

    return Dictionary(uniqueKeysWithValues: models)
  }()
}

struct ResolvedHuggingFaceModel: Equatable, Sendable {
  let modelName: String
  let displayName: String
  let approximateSizeMB: Int
}

struct LocalStreamingModelSource: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let repoID: String
  let modelName: String
  let runtime: String
  let approximateSizeMB: Int?

  init(repoID: String, modelName: String, runtime: String? = nil, approximateSizeMB: Int? = nil) {
    let repoID = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
    let modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    self.id = "local/streaming/huggingface/\(LocalModelManager.slug(repoID))/\(LocalModelManager.slug(modelName))"
    self.repoID = repoID
    self.modelName = modelName
    self.runtime = runtime ?? LocalModelManager.streamingRuntimeHint(for: repoID, modelName: modelName)
    self.approximateSizeMB = approximateSizeMB
      ?? LocalModelManager.streamingApproximateSizeMB(repoID: repoID, modelName: modelName)
  }

  var displayName: String {
    "\(modelName) from \(repoID)"
  }
}

private struct ImportedModelRecord: Codable {
  let id: String
  let displayName: String
  let modelName: String
  let engine: String
  let modelRepo: String?
  let approximateSizeMB: Int
  let description: String
  let supportsLiveStreaming: Bool

  init(model: LocalTranscriptionModel) {
    id = model.id
    displayName = model.displayName
    modelName = model.modelName
    engine = model.engine
    modelRepo = model.modelRepo
    approximateSizeMB = model.approximateSizeMB
    description = model.description
    supportsLiveStreaming = model.supportsLiveStreaming
  }

  var model: LocalTranscriptionModel {
    LocalTranscriptionModel(
      id: id,
      displayName: displayName,
      modelName: modelName,
      engine: engine,
      modelRepo: modelRepo,
      approximateSizeMB: approximateSizeMB,
      description: description,
      tags: [.quality],
      supportsLiveStreaming: supportsLiveStreaming
    )
  }
}
