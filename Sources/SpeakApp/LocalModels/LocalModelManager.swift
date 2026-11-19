import Foundation
import OSLog
import SpeakCore
import class WhisperKit.WhisperKit
import class WhisperKit.WhisperKitConfig

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
  #if !APP_STORE
  @Published private(set) var streamingModelSources: [LocalStreamingModelSource] = []

  /// The canonical sherpa-onnx catalogue. It needs an installable runtime, so
  /// App Store builds do not compile this projection.
  nonisolated static var recommendedStreamingModelSources: [LocalStreamingModelSource] {
    ModelCatalog.localStreamingSources
  }
  #endif

  @Published private var activePipelineUses: [String: Int] = [:]
  private let logger = SpeakLogger.logger(category: "LocalModelManager")
  private let markerDirectory: URL
  private let modelStorage: WhisperKitModelStorage
  private let markers: WhisperKitInstallMarkers
  private let pipelines: WhisperKitPipelineCache
  private let sourceStore: LocalTranscriptionSourceStore
  private let fileTranscriber: @MainActor (WhisperKit, String) async throws -> String
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
    self.fileTranscriber = fileTranscriber
    markerDirectory = storageDirectory ?? LocalModelsDirectory.root(fileManager: fileManager)
    let modelStorage = modelStorage ?? WhisperKitModelStorage(
      root: markerDirectory.appendingPathComponent("WhisperKitDownloads", isDirectory: true), fileManager: fileManager
    )
    self.modelStorage = modelStorage
    markers = WhisperKitInstallMarkers(directory: markerDirectory, fileManager: fileManager, modelStorage: modelStorage)
    pipelines = WhisperKitPipelineCache(modelStorage: modelStorage, pipelineLoader: pipelineLoader)
    sourceStore = LocalTranscriptionSourceStore(directory: markerDirectory, fileManager: fileManager)
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

  #if !APP_STORE
  private var phonon: PhononRuntime {
    PhononRuntime(root: markerDirectory.appendingPathComponent("Phonon", isDirectory: true))
  }
  #endif

  var availableModels: [LocalTranscriptionModel] {
    ModelCatalog.availableLocalTranscription + importedModels
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
    pipelines.isLoaded(modelID)
  }

  func model(for modelID: String) -> LocalTranscriptionModel? {
    let normalizedID = Self.normalizedLocalModelID(modelID)
    return availableModels.first { $0.id == modelID || $0.id == normalizedID }
  }

  @discardableResult
  func importHuggingFaceModel(repoID: String, modelName: String) throws -> LocalTranscriptionModel {
    let model = try LocalTranscriptionSourceStore.importedModel(repoID: repoID, modelName: modelName)
    importedModels.removeAll {
      $0.id == model.id || ($0.modelRepo == model.modelRepo && $0.modelName == model.modelName)
    }
    importedModels.append(model)
    try sourceStore.saveImportedModels(importedModels)
    refreshInstallState(for: model)
    return model
  }

  func install(_ model: LocalTranscriptionModel) async {
    guard !isModelBusy(model.id), self.model(for: model.id) != nil else { return }
    installStates[model.id] = .installing
    do {
      #if !APP_STORE
      if model.engine == .phonon {
        try await phonon.install()
        installStates[model.id] = .installed
        return
      }
      #endif
      _ = try await pipelines.pipeline(for: model, useManagedStorage: true)
      try markers.recordManagedInstall(for: model)
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
      #if !APP_STORE
      if model.engine == .phonon {
        try phonon.deleteModel()
        installStates[model.id] = .notInstalled
        return true
      }
      #endif
      pipelines.evict(model.id)
      try modelStorage.removeDownload(for: model.id)
      try markers.remove(for: model)
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
    #if !APP_STORE
    if model.engine == .phonon {
      return try await phonon.transcribe(url, language: language)
    }
    #endif
    let start = Date()
    let pipe = try await pipelines.pipeline(for: model)
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
    return try await pipelines.pipeline(for: model)
  }

  /// A live stream owns its files until capture, in-flight decoding, and the
  /// final tail decode have all released the lease, including timed-out work.
  func makeReadyPipelineLease(modelID: String) async throws -> LocalModelPipelineLease {
    guard let model = model(for: modelID) else { throw LocalModelError.unknownModel(modelID) }
    guard isInstalled(model.id) else { throw LocalModelError.notInstalled(model.displayName) }
    activePipelineUses[model.id, default: 0] += 1
    do {
      try Task.checkCancellation()
      let pipe = try await pipelines.pipeline(for: model)
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

  func canDelete(_ model: LocalTranscriptionModel) -> Bool {
    #if !APP_STORE
    if model.engine == .phonon { return !isModelBusy(model.id) && phonon.hasDownload }
    #endif
    return !isModelBusy(model.id)
      && (markers.exists(for: model) || (try? modelStorage.hasDownload(for: model.id)) == true)
  }

  private func isModelBusy(_ modelID: String) -> Bool {
    installStates[modelID] == .installing
      || pipelines.isLoading(modelID) || activePipelineUses[modelID, default: 0] > 0
  }

  /// Whether this install still uses the dependency-managed legacy cache.
  func usesLegacyStorage(_ model: LocalTranscriptionModel) -> Bool {
    markers.usesLegacyStorage(model)
  }

  func configuration(for model: LocalTranscriptionModel, managedStorage: Bool) throws -> WhisperKitConfig {
    try pipelines.configuration(for: model, managedStorage: managedStorage)
  }

  private func cleanTranscriptText(_ text: String) -> String {
    text
      .replacingOccurrences(of: "[BLANK_AUDIO]", with: "", options: .caseInsensitive)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func refreshInstallState(for model: LocalTranscriptionModel) {
    #if !APP_STORE
    if model.engine == .phonon {
      installStates[model.id] = phonon.isInstalled ? .installed : .notInstalled
      return
    }
    #endif
    installStates[model.id] = markers.installState(for: model)
  }

  private func loadImportedModels() {
    do {
      importedModels = try sourceStore.loadImportedModels()
    } catch {
      logger.error("Failed to load imported Hugging Face models: \(error.localizedDescription, privacy: .private)")
    }
  }
}

extension LocalModelManager {
    func reloadAfterMigration() {
        importedModels = []
        loadImportedModels()
        #if !APP_STORE
        streamingModelSources = []
        loadStreamingModelSources()
        #endif
        refreshInstallStates()
    }
}

#if !APP_STORE
// User-added sherpa-onnx streaming sources.
extension LocalModelManager {
  @discardableResult
  func addStreamingModelSource(repoID: String, modelName: String) throws -> LocalStreamingModelSource {
    let source = try LocalTranscriptionSourceStore.streamingSource(repoID: repoID, modelName: modelName)
    try addStreamingModelSource(source)
    return source
  }

  @discardableResult
  func addStreamingModelSource(_ source: LocalStreamingModelSource) throws -> LocalStreamingModelSource {
    streamingModelSources.removeAll { $0.id == source.id }
    streamingModelSources.append(source)
    try sourceStore.saveStreamingSources(streamingModelSources)
    return source
  }

  func deleteStreamingModelSource(_ source: LocalStreamingModelSource) {
    streamingModelSources.removeAll { $0.id == source.id }
    do {
      try sourceStore.saveStreamingSources(streamingModelSources)
    } catch {
      logger.error("Failed to save local streaming model sources: \(error.localizedDescription, privacy: .private)")
    }
  }

  private func loadStreamingModelSources() {
    do {
      streamingModelSources = try sourceStore.loadStreamingSources()
    } catch {
      logger.error("Failed to load local streaming model sources: \(error.localizedDescription, privacy: .private)")
    }
  }
}
#endif
