import Foundation
import OSLog
import SpeakCore

@MainActor
final class LocalPostProcessingModelManager: ObservableObject {
  static let shared = LocalPostProcessingModelManager()

  enum InstallState: Equatable {
    case notInstalled
    case installing
    case installed
    case failed(String)

    var isInstalled: Bool {
      if case .installed = self { return true }
      return false
    }
  }

  nonisolated static var builtInRulesModelID: String {
    LocalPostProcessingModel.builtInRulesModelID
  }

  #if !APP_STORE
  /// The canonical GGUF catalogue. It needs the installable llama.cpp runtime,
  /// so App Store builds do not compile this projection.
  nonisolated static var recommendedModels: [LocalPostProcessingModel] {
    ModelCatalog.localPostProcessing
  }

  @Published private(set) var runtimeState: InstallState = .notInstalled
  @Published private(set) var modelStates: [String: InstallState] = [:]
  @Published private(set) var importedModels: [LocalPostProcessingModel] = []
  #endif

  private let fileManager: FileManager
  private let logger = SpeakLogger.logger(category: "LocalPostProcessing")
  #if !APP_STORE
  private let baseDirectory: URL
  private let modelsDirectory: URL
  private let runtimeDirectory: URL
  private let runtime: LlamaCppRuntime
  private let importedModelsFile: LocalModelSourceFile<LocalPostProcessingModel>
  #endif

  private init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    #if !APP_STORE
    baseDirectory = LocalModelsDirectory.root(fileManager: fileManager)
      .appendingPathComponent("LocalPostProcessing", isDirectory: true)
    modelsDirectory = baseDirectory.appendingPathComponent("Models", isDirectory: true)
    runtimeDirectory = baseDirectory.appendingPathComponent("runtime", isDirectory: true)
    runtime = LlamaCppRuntime(
      baseDirectory: baseDirectory, runtimeDirectory: runtimeDirectory, fileManager: fileManager
    )
    importedModelsFile = LocalModelSourceFile(
      url: baseDirectory.appendingPathComponent("imported-hugging-face-gguf-models.json"), fileManager: fileManager
    )
    do {
      try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
      try runtime.writeScriptIfNeeded()
    } catch {
      runtimeState = .failed(error.localizedDescription)
    }
    loadImportedModels()
    refresh()
    #endif
  }

  var availableModels: [LocalPostProcessingModel] {
    #if APP_STORE
    []
    #else
    Self.recommendedModels + importedModels
    #endif
  }

  var availableModelOptions: [ModelCatalog.Option] {
    availableModels.map(\.option)
  }

  func refresh() {
    #if !APP_STORE
    Task { await refreshRuntimeState() }
    for model in availableModels {
      if modelStates[model.id] == .installing {
        continue
      }
      modelStates[model.id] = modelFileExists(for: model) ? .installed : .notInstalled
    }
    #endif
  }

  func installState(for modelID: String) -> InstallState {
    #if APP_STORE
    .notInstalled
    #else
    modelStates[modelID] ?? .notInstalled
    #endif
  }

  func isInstalled(_ modelID: String) -> Bool {
    installState(for: modelID).isInstalled
  }

  func model(for modelID: String) -> LocalPostProcessingModel? {
    availableModels.first { $0.id == modelID }
  }

  #if !APP_STORE
  @discardableResult
  func addHuggingFaceModel(
    repoID: String,
    filename: String,
    approximateSizeMB: Int?
  ) throws -> LocalPostProcessingModel {
    let repoID = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
    let filename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    guard HuggingFaceRepoInput.isValidRepoID(repoID) else {
      throw LocalPostProcessingModelError.invalidHuggingFaceSource(
        "Use owner/repo, for example unsloth/Qwen3-0.6B-GGUF."
      )
    }
    guard LocalPostProcessingModel.isGGUFFilename(filename) else {
      throw LocalPostProcessingModelError.invalidHuggingFaceSource("The file must be a .gguf model file.")
    }

    let model = LocalPostProcessingModel.importedModel(
      repoID: repoID,
      filename: filename,
      approximateSizeMB: approximateSizeMB
    )
    importedModels.removeAll { $0.id == model.id }
    importedModels.append(model)
    try importedModelsFile.save(importedModels)
    modelStates[model.id] = modelFileExists(for: model) ? .installed : .notInstalled
    return model
  }

  func installRuntime() async {
    guard runtimeState != .installing else { return }
    let previousState = runtimeState
    runtimeState = .installing
    do {
      try await runtime.install()
      try Task.checkCancellation()
      runtimeState = .installed
    } catch is CancellationError {
      runtimeState = previousState
    } catch {
      runtimeState = .failed(LlamaCppRuntime.readableInstallError(from: error))
    }
  }

  func installModel(_ model: LocalPostProcessingModel) async {
    guard modelStates[model.id] != .installing else { return }
    modelStates[model.id] = .installing
    do {
      try await StagedModelInstall.install(at: modelFileURL(for: model), fileManager: fileManager) { tempURL in
        try await downloadFile(repoID: model.repoID, filename: model.filename, to: tempURL)
      }
      modelStates[model.id] = .installed
    } catch {
      modelStates[model.id] = .failed(error.localizedDescription)
    }
  }

  func deleteModel(_ model: LocalPostProcessingModel) {
    do {
      let url = modelFileURL(for: model)
      if fileManager.fileExists(atPath: url.path) {
        try fileManager.removeItem(at: url)
      }
      modelStates[model.id] = .notInstalled
    } catch {
      modelStates[model.id] = .failed(error.localizedDescription)
    }
  }

  func process(
    modelID: String,
    rawText: String,
    systemPrompt: String,
    temperature: Double
  ) async throws -> String {
    try await run(
      modelID: modelID,
      systemPrompt: LocalPostProcessingPrompt.systemPrompt(systemPrompt),
      userPrompt: LocalPostProcessingPrompt.userPrompt(rawText: rawText),
      rawText: rawText,
      temperature: temperature
    )
  }

  /// Runs the model with an explicit prompt pair, preserved verbatim (plus
  /// the local-engine constraint). Used by the Polish Text App Intent when
  /// the user supplies a custom prompt: rebuilding the stock cleanup payload
  /// here would silently perform cleanup instead of honouring the prompt.
  func processWithExplicitPrompt(
    modelID: String,
    systemPrompt: String,
    userMessage: String,
    temperature: Double
  ) async throws -> String {
    try await run(
      modelID: modelID,
      systemPrompt: LocalPostProcessingPrompt.explicitSystemPrompt(systemPrompt),
      userPrompt: userMessage,
      rawText: userMessage,
      temperature: temperature
    )
  }

  private func run(
    modelID: String,
    systemPrompt: String,
    userPrompt: String,
    rawText: String,
    temperature: Double
  ) async throws -> String {
    guard let model = model(for: modelID) else {
      throw LocalPostProcessingModelError.unknownModel(modelID)
    }
    guard isInstalled(model.id) else {
      throw LocalPostProcessingModelError.modelNotInstalled(model.displayName)
    }
    let request = LocalPostProcessingRequest(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      rawText: rawText,
      temperature: temperature
    )
    let response = try await runtime.complete(request, modelURL: modelFileURL(for: model))
    let cleanedResponse = LocalPostProcessingPrompt.sanitizedModelOutput(response.text)
    guard !cleanedResponse.isEmpty else {
      throw LocalPostProcessingModelError.processFailed("The local model returned an empty response.")
    }
    if response.truncated == true {
      logger.warning("Local post-processing output reached the model output limit; returning partial generated text.")
    }
    return cleanedResponse
  }

  private func refreshRuntimeState() async {
    guard runtimeState != .installing else { return }
    do {
      try await runtime.ensureAvailable()
      try Task.checkCancellation()
      runtimeState = .installed
    } catch is CancellationError {
      return
    } catch {
      runtimeState = .notInstalled
    }
  }

  private func modelFileExists(for model: LocalPostProcessingModel) -> Bool {
    fileManager.fileExists(atPath: modelFileURL(for: model).path)
  }

  private func modelFileURL(for model: LocalPostProcessingModel) -> URL {
    modelsDirectory
      .appendingPathComponent(model.id.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
      .appendingPathComponent(model.filename)
  }

  private func downloadFile(repoID: String, filename: String, to destination: URL) async throws {
    try await HuggingFaceFileDownload.download(
      repoID: repoID, filename: filename, to: destination, fileManager: fileManager,
      failure: LocalPostProcessingModelError.downloadFailed
    )
  }

  private func loadImportedModels() {
    do {
      if let models = try importedModelsFile.load() {
        importedModels = models
      }
    } catch {
      logger.error(
        "Failed to load local post-processing model sources: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
  #endif
}

// Identity rules are canonical in SpeakCore; these forwarders keep existing
// macOS call sites unchanged.
extension LocalPostProcessingModelManager {
  nonisolated static func isDownloadedLocalModelID(_ id: String) -> Bool {
    LocalPostProcessingModel.isDownloadedModelID(id)
  }

  nonisolated static func huggingFaceModelID(repoID: String, filename: String) -> String {
    LocalPostProcessingModel.huggingFaceModelID(repoID: repoID, filename: filename)
  }

  nonisolated static func approximateSizeMB(from filename: String) -> Int? {
    LocalPostProcessingModel.approximateSizeMB(fromFilename: filename)
  }
}

extension LocalPostProcessingModel {
  var sizeLabel: String {
    guard let approximateSizeMB, approximateSizeMB > 0 else { return "Size unknown" }
    if approximateSizeMB >= 1024 {
      let gigabytes = Double(approximateSizeMB) / 1024
      return "\(gigabytes.formatted(.number.precision(.fractionLength(1)))) GB"
    }
    return "\(approximateSizeMB) MB"
  }
}

extension LocalPostProcessingModelManager {
    func reloadAfterMigration() {
        #if !APP_STORE
        importedModels = []
        loadImportedModels()
        #endif
        refresh()
    }
}
