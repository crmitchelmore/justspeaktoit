import Foundation
import OSLog
import SpeakCore
import class WhisperKit.WhisperKit
import class WhisperKit.WhisperKitConfig

// swiftlint:disable file_length
enum LocalModelError: LocalizedError {
  case unknownModel(String)
  case notInstalled(String)
  case emptyTranscript(String)
  case invalidHuggingFaceRepo(String)
  case invalidHuggingFaceModel
  case modelBusy
  case missingManagedModelFolder

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
    case .modelBusy:
      return "The model is loading or transcribing. Wait for it to finish before deleting it."
    case .missingManagedModelFolder:
      return "The model files are missing. Download this model again to restore them."
    case .invalidHuggingFaceModel:
      #if APP_STORE
      return "Enter a supported local batch model name. Local Batch expects a WhisperKit variant."
      #else
      return """
      Enter a supported local model name. Local Batch expects a WhisperKit variant; \
      Local Streaming expects a sherpa-onnx streaming ASR source.
      """
      #endif
    }
  }
}

@MainActor
// swiftlint:disable:next type_body_length
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
  #if !APP_STORE
  @Published private(set) var streamingModelSources: [LocalStreamingModelSource] = []

  static let recommendedStreamingModelSources: [LocalStreamingModelSource] = [
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
  #endif

  private var activePipelines: [String: WhisperKit] = [:]
  private var loadingPipelines: [String: Task<WhisperKit, Error>] = [:]
  @Published private var activePipelineUses: [String: Int] = [:]
  private let fileManager: FileManager
  private let logger = SpeakLogger.logger(category: "LocalModelManager")
  private let markerDirectory: URL
  private let modelStorage: WhisperKitModelStorage
  private let pipelineLoader: @MainActor (WhisperKitConfig) async throws -> WhisperKit
  private let fileTranscriber: @MainActor (WhisperKit, String) async throws -> String
  private let importedModelsURL: URL
  #if !APP_STORE
  private let streamingModelSourcesURL: URL
  #endif
  private var storageError: Error?

  /// Test accounting. `shared` is lazy, so an unchanged count across an operation proves
  /// that operation did not force the singleton (and its filesystem work) into existence.
  /// Not gated on DEBUG: CI also runs the tests in the Release configuration.
  private(set) static var instanceCount = 0

  init(
    fileManager: FileManager = .default,
    storageDirectory: URL? = nil,
    modelStorage: WhisperKitModelStorage? = nil,
    pipelineLoader: @escaping @MainActor (WhisperKitConfig) async throws -> WhisperKit = {
      try await WhisperKitOffMain.load($0)
    },
    fileTranscriber: @escaping @MainActor (WhisperKit, String) async throws -> String = { pipeline, path in
      try await WhisperKitOffMain.transcribe(pipeline, audioPath: path).map(\.text).joined(separator: " ")
    }
  ) {
    Self.instanceCount += 1
    self.fileManager = fileManager
    self.pipelineLoader = pipelineLoader
    self.fileTranscriber = fileTranscriber
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
    let defaultStorageDirectory = base
      .appendingPathComponent("SpeakApp", isDirectory: true)
      .appendingPathComponent("LocalModels", isDirectory: true)
    markerDirectory = storageDirectory ?? defaultStorageDirectory
    self.modelStorage = modelStorage ?? WhisperKitModelStorage(
      root: markerDirectory.appendingPathComponent("WhisperKitDownloads", isDirectory: true), fileManager: fileManager
    )
    importedModelsURL = markerDirectory.appendingPathComponent("imported-hugging-face-models.json")
    #if !APP_STORE
    streamingModelSourcesURL = markerDirectory.appendingPathComponent("streaming-model-sources.json")
    #endif
    do {
      try fileManager.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
    } catch {
      storageError = error
      logger.error("Failed to prepare local model storage: \(error.localizedDescription, privacy: .private)")
    }
    loadImportedModels()
    #if !APP_STORE
    loadStreamingModelSources()
    #endif
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
      if installStates[model.id] == .installing {
        continue
      }
      refreshInstallState(for: model)
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
    let normalizedID = Self.normalizedLocalModelID(modelID)
    return availableModels.first { $0.id == modelID || $0.id == normalizedID }
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
      engine: .whisperKit,
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
    refreshInstallState(for: model)
    return model
  }

  #if !APP_STORE
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
      logger.error("Failed to save local streaming model sources: \(error.localizedDescription, privacy: .private)")
    }
  }
  #endif

  func install(_ model: LocalTranscriptionModel) async {
    guard loadingPipelines[model.id] == nil else { return }
    installStates[model.id] = .installing
    do {
      _ = try await pipeline(for: model, useManagedStorage: true)
      try Data("installed-managed-v1\n".utf8).write(to: markerURL(for: model), options: .atomic)
      installStates[model.id] = .installed
    } catch {
      installStates[model.id] = .failed(error.localizedDescription)
    }
  }

  @discardableResult
  func delete(_ model: LocalTranscriptionModel) -> Bool {
    guard !isModelBusy(model.id) else {
      logger.warning("Cannot remove local model: \(LocalModelError.modelBusy.localizedDescription, privacy: .public)")
      return false
    }
    do {
      activePipelines[model.id] = nil
      try modelStorage.removeDownload(for: model.id)
      let markerURL = markerURL(for: model)
      if fileManager.fileExists(atPath: markerURL.path) {
        try fileManager.removeItem(at: markerURL)
      }
      installStates[model.id] = .notInstalled
      return true
    } catch {
      installStates[model.id] = .failed(error.localizedDescription)
      logger.error("Failed to remove local model: \(error.localizedDescription, privacy: .private)")
      return false
    }
  }

  func transcribeFile(at url: URL, modelID: String, language: String?) async throws -> TranscriptionResult {
    guard let model = model(for: modelID) else {
      throw LocalModelError.unknownModel(modelID)
    }
    guard isInstalled(model.id) else {
      throw LocalModelError.notInstalled(model.displayName)
    }

    // Hold the files through loading and every suspended inference. Cancellation
    // only releases this lease once the decoder has actually unwound.
    activePipelineUses[model.id, default: 0] += 1
    defer { releasePipelineUse(for: model.id) }
    try Task.checkCancellation()
    let start = Date()
    let pipe = try await pipeline(for: model)
    try Task.checkCancellation()
    let text = cleanTranscriptText(try await fileTranscriber(pipe, url.path))
    try Task.checkCancellation()
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

  func makeReadyPipeline(modelID: String) async throws -> WhisperKit {
    guard let model = model(for: modelID) else {
      throw LocalModelError.unknownModel(modelID)
    }
    guard isInstalled(model.id) else {
      throw LocalModelError.notInstalled(model.displayName)
    }
    return try await pipeline(for: model)
  }

  /// A live stream owns its files until capture, in-flight decoding, and the
  /// final tail decode have all released the lease, including timed-out work.
  func makeReadyPipelineLease(modelID: String) async throws -> LocalModelPipelineLease {
    guard let model = model(for: modelID) else { throw LocalModelError.unknownModel(modelID) }
    guard isInstalled(model.id) else { throw LocalModelError.notInstalled(model.displayName) }
    activePipelineUses[model.id, default: 0] += 1
    do {
      try Task.checkCancellation()
      let pipe = try await pipeline(for: model)
      try Task.checkCancellation()
      return LocalModelPipelineLease(pipeline: pipe) { self.releasePipelineUse(for: model.id) }
    } catch {
      releasePipelineUse(for: model.id)
      throw error
    }
  }

  private func releasePipelineUse(for modelID: String) {
    activePipelineUses[modelID, default: 0] -= 1
    if activePipelineUses[modelID] == 0 { activePipelineUses[modelID] = nil }
  }

  private func pipeline(
    for model: LocalTranscriptionModel, useManagedStorage: Bool = false
  ) async throws -> WhisperKit {
    let hasOwnership = try modelStorage.hasOwnership(for: model.id)
    let managed = useManagedStorage || hasOwnership
    if let existing = activePipelines[model.id] {
      if !managed { return existing }
      if let folder = try modelStorage.modelFolder(for: model.id),
         existing.modelFolder?.standardizedFileURL == folder.standardizedFileURL {
        return existing
      }
      // Preparing managed storage writes provenance before download. That
      // record must not let a legacy cached pipeline survive a failed upgrade.
      activePipelines[model.id] = nil
    }
    if let loading = loadingPipelines[model.id] {
      return try await loading.value
    }

    let config = try configuration(for: model, managedStorage: managed)
    let task = Task<WhisperKit, Error> {
      try await self.pipelineLoader(config)
    }
    loadingPipelines[model.id] = task
    defer { loadingPipelines[model.id] = nil }

    let pipe = try await task.value
    if managed {
      guard let folder = pipe.modelFolder else { throw LocalModelError.missingManagedModelFolder }
      try modelStorage.recordModelFolder(folder, for: model.id)
    }
    activePipelines = [:]
    activePipelines[model.id] = pipe
    return pipe
  }

  func canDelete(_ model: LocalTranscriptionModel) -> Bool {
    !isModelBusy(model.id) && (markerExists(for: model) || (try? modelStorage.hasDownload(for: model.id)) == true)
  }

  private func isModelBusy(_ modelID: String) -> Bool {
    loadingPipelines[modelID] != nil || activePipelineUses[modelID, default: 0] > 0
  }

  /// Legacy installs continue using their dependency-managed cache. Only an
  /// explicit installation selects a new owned base; deletion never guesses the
  /// old cache path. Reinstalling after removal migrates future downloads.
  func usesLegacyStorage(_ model: LocalTranscriptionModel) -> Bool {
    let marker = try? String(contentsOf: markerURL(for: model), encoding: .utf8)
    return marker != nil && marker != "installed-managed-v1\n"
      && (try? modelStorage.hasOwnership(for: model.id)) == false
  }

  func configuration(for model: LocalTranscriptionModel, managedStorage: Bool) throws -> WhisperKitConfig {
    let base = managedStorage ? try modelStorage.prepare(for: model.id) : nil
    let folder = managedStorage ? try modelStorage.modelFolder(for: model.id) : nil
    // Pinned argmax-oss-swift 1.1.0: modelFolder bypasses model downloading;
    // downloadBase also owns tokenizer storage unless tokenizerFolder is set.
    return WhisperKitConfig(
      model: model.modelName,
      downloadBase: base,
      modelRepo: model.modelRepo,
      modelFolder: folder?.path,
      tokenizerFolder: base,
      verbose: false,
      load: true,
      download: folder == nil
    )
  }

  private func cleanTranscriptText(_ text: String) -> String {
    text
      .replacingOccurrences(of: "[BLANK_AUDIO]", with: "", options: .caseInsensitive)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func refreshInstallState(for model: LocalTranscriptionModel) {
    guard markerExists(for: model) else {
      installStates[model.id] = .notInstalled
      return
    }
    do {
      let marker = try String(contentsOf: markerURL(for: model), encoding: .utf8)
      let hasOwnership = try modelStorage.hasOwnership(for: model.id)
      if marker == "installed-managed-v1\n" || hasOwnership {
        guard try modelStorage.modelFolder(for: model.id) != nil else {
          throw LocalModelError.missingManagedModelFolder
        }
      }
      installStates[model.id] = .installed
    } catch {
      installStates[model.id] = .failed(error.localizedDescription)
    }
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
        let migrated = Self.normalizedImportedModel(record.model)
        if migrated != record.model {
          didMigrate = true
        }
        return migrated
      }
      importedModels = Self.deduplicateModels(migratedModels)
      if didMigrate {
        try? saveImportedModels()
      }
    } catch {
      logger.error("Failed to load imported Hugging Face models: \(error.localizedDescription, privacy: .private)")
    }
  }

  #if !APP_STORE
  private func loadStreamingModelSources() {
    guard fileManager.fileExists(atPath: streamingModelSourcesURL.path) else { return }
    do {
      let data = try Data(contentsOf: streamingModelSourcesURL)
      let decoded = try JSONDecoder().decode([LocalStreamingModelSource].self, from: data)
      let migratedSources = decoded
        .filter(Self.isSupportedStreamingSource)
        .map(Self.normalizedStreamingModelSource)
      streamingModelSources = migratedSources
      if streamingModelSources.count != decoded.count || streamingModelSources != decoded {
        try? saveStreamingModelSources()
      }
    } catch {
      logger.error("Failed to load local streaming model sources: \(error.localizedDescription, privacy: .private)")
    }
  }
  #endif

  private func saveImportedModels() throws {
    let records = importedModels.map(ImportedModelRecord.init(model:))
    let data = try JSONEncoder().encode(records)
    try data.write(to: importedModelsURL, options: .atomic)
  }

  #if !APP_STORE
  private func saveStreamingModelSources() throws {
    let data = try JSONEncoder().encode(streamingModelSources)
    try data.write(to: streamingModelSourcesURL, options: .atomic)
  }
  #endif

  nonisolated static func huggingFaceModelID(repoID: String, modelName: String) -> String {
    "local/whisperkit/huggingface/\(slug(repoID))/\(slug(modelName))"
  }

  nonisolated static func normalizedLocalModelID(_ identifier: String) -> String {
    let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "local/whisperkit/huggingface/"
    guard trimmed.lowercased().hasPrefix(prefix) else { return trimmed }

    let remainder = String(trimmed.dropFirst(prefix.count))
    let components = remainder.split(separator: "/").map(String.init)
    guard components.count >= 3 else { return trimmed }

    let repoID = "\(components[0])/\(components[1])"
    let modelSlug = components.dropFirst(2).joined(separator: "/")
    let resolved = resolveHuggingFaceModel(repoID: repoID, modelName: modelSlug)
    return huggingFaceModelID(repoID: repoID, modelName: resolved.modelName)
  }

  nonisolated static func normalizedImportedModel(_ model: LocalTranscriptionModel) -> LocalTranscriptionModel {
    guard let repoID = model.modelRepo else { return model }
    let resolved = resolveHuggingFaceModel(repoID: repoID, modelName: model.modelName)
    let expectedID = huggingFaceModelID(repoID: repoID, modelName: resolved.modelName)
    guard expectedID != model.id
      || resolved.modelName != model.modelName
      || resolved.approximateSizeMB != model.approximateSizeMB
    else {
      return model
    }
    return LocalTranscriptionModel(
      id: expectedID,
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

  #if !APP_STORE
  nonisolated static func normalizedStreamingModelSource(_ source: LocalStreamingModelSource) -> LocalStreamingModelSource { // swiftlint:disable:this line_length
    LocalStreamingModelSource(
      repoID: source.repoID,
      modelName: source.modelName,
      runtime: streamingRuntimeHint(for: source.repoID, modelName: source.modelName),
      approximateSizeMB: source.approximateSizeMB
        ?? streamingApproximateSizeMB(repoID: source.repoID, modelName: source.modelName),
      archiveURL: source.archiveURL
    )
  }
  #endif

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

  #if !APP_STORE
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

  nonisolated static func isSupportedStreamingSource(_ source: LocalStreamingModelSource) -> Bool {
    let text = "\(source.id) \(source.repoID) \(source.modelName) \(source.runtime)".lowercased()
    // Only sherpa-onnx exports are runnable; raw NeMo checkpoints from
    // nvidia/* repos are not. Parakeet is supported solely as the sherpa-onnx
    // nemo-parakeet-tdt-0.6b-v3 conversion.
    guard text.contains("sherpa"), !text.contains("nvidia") else { return false }
    let isNemotron = text.contains("nemotron")
    let isSherpaParakeetV3 = text.contains("nemo-parakeet-tdt-0.6b-v3")
    guard isNemotron || isSherpaParakeetV3 || !text.contains("nemo") else { return false }
    return text.contains("zipformer") || isNemotron || isSherpaParakeetV3
  }
  #endif

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
        [
          "openai_whisper-large-v3_turbo",
          "openai_whisper-large-v3_turbo_954mb",
          "openai-whisper-large-v3-turbo",
          "openai-whisper-large-v3-turbo-954mb"
        ],
        name: "openai_whisper-large-v3_turbo_954MB",
        displayName: "Whisper Large v3 Turbo",
        size: 954
      )
    ].flatMap { $0 }

    return Dictionary(uniqueKeysWithValues: models)
  }()
}

struct ResolvedHuggingFaceModel: Equatable, Sendable {
  let modelName: String
  let displayName: String
  let approximateSizeMB: Int
}

#if !APP_STORE
struct LocalStreamingModelSource: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let repoID: String
  let modelName: String
  let runtime: String
  let approximateSizeMB: Int?
  let archiveURL: URL?

  init(
    repoID: String,
    modelName: String,
    runtime: String? = nil,
    approximateSizeMB: Int? = nil,
    archiveURL: URL? = nil
  ) {
    let repoID = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
    let modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    self.id = "local/streaming/huggingface/\(LocalModelManager.slug(repoID))/\(LocalModelManager.slug(modelName))"
    self.repoID = repoID
    self.modelName = modelName
    self.runtime = runtime ?? LocalModelManager.streamingRuntimeHint(for: repoID, modelName: modelName)
    self.approximateSizeMB = approximateSizeMB
      ?? LocalModelManager.streamingApproximateSizeMB(repoID: repoID, modelName: modelName)
    self.archiveURL = archiveURL
  }

  var displayName: String {
    "\(modelName) from \(repoID)"
  }
}
#endif

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
    engine = model.engine.identifier
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
      engine: LocalTranscriptionEngine(identifier: engine),
      modelRepo: modelRepo,
      approximateSizeMB: approximateSizeMB,
      description: description,
      tags: [.quality],
      supportsLiveStreaming: supportsLiveStreaming
    )
  }
}
