import Foundation
import SpeakCore

/// The persisted `imported-hugging-face-models.json` record, defined in SpeakCore.
typealias ImportedModelRecord = LocalTranscriptionModelRecord

/// The user's imported WhisperKit models and added sherpa-onnx streaming
/// sources. Both lists are migrated as they load, and a migrated list is
/// written back so the next launch reads canonical entries.
struct LocalTranscriptionSourceStore {
  private let importedModelsFile: LocalModelSourceFile<ImportedModelRecord>
  #if !APP_STORE
  private let streamingSourcesFile: LocalModelSourceFile<LocalStreamingModelSource>
  #endif

  init(directory: URL, fileManager: FileManager = .default) {
    importedModelsFile = LocalModelSourceFile(
      url: directory.appendingPathComponent("imported-hugging-face-models.json"), fileManager: fileManager
    )
    #if !APP_STORE
    streamingSourcesFile = LocalModelSourceFile(
      url: directory.appendingPathComponent("streaming-model-sources.json"), fileManager: fileManager
    )
    #endif
  }

  /// Imported models with legacy identifiers normalised. When two records
  /// resolve to one identifier, the later import wins.
  func loadImportedModels() throws -> [LocalTranscriptionModel] {
    guard let records = try importedModelsFile.load() else { return [] }
    var didMigrate = false
    let migratedModels = records.map { record in
      let migrated = WhisperKitHuggingFaceModels.normalizedImportedModel(record.model)
      if migrated != record.model {
        didMigrate = true
      }
      return migrated
    }
    let models = Self.deduplicateModels(migratedModels)
    if didMigrate {
      try? saveImportedModels(models)
    }
    return models
  }

  func saveImportedModels(_ models: [LocalTranscriptionModel]) throws {
    try importedModelsFile.save(models.map(ImportedModelRecord.init(model:)))
  }

  #if !APP_STORE
  /// Streaming sources the sherpa-onnx runtime can run, normalised. Sources it
  /// can no longer run are dropped from the file.
  func loadStreamingSources() throws -> [LocalStreamingModelSource] {
    guard let decoded = try streamingSourcesFile.load() else { return [] }
    let migratedSources = decoded
      .filter(LocalStreamingModelSource.isRunnableSherpaOnnxSource)
      .map(LocalStreamingModelSource.normalized)
    if migratedSources.count != decoded.count || migratedSources != decoded {
      try? saveStreamingSources(migratedSources)
    }
    return migratedSources
  }

  func saveStreamingSources(_ sources: [LocalStreamingModelSource]) throws {
    try streamingSourcesFile.save(sources)
  }
  #endif

  /// The WhisperKit model a "Hugging Face model" form describes.
  static func importedModel(repoID: String, modelName: String) throws -> LocalTranscriptionModel {
    let (repoID, modelName) = try validatedSource(repoID: repoID, modelName: modelName)
    return WhisperKitHuggingFaceModels.importedModel(repoID: repoID, modelName: modelName)
  }

  #if !APP_STORE
  /// The streaming source a "Hugging Face model" form describes, when the
  /// sherpa-onnx runtime can run it.
  static func streamingSource(repoID: String, modelName: String) throws -> LocalStreamingModelSource {
    let (repoID, modelName) = try validatedSource(repoID: repoID, modelName: modelName)
    let source = LocalStreamingModelSource(repoID: repoID, modelName: modelName)
    guard LocalStreamingModelSource.isRunnableSherpaOnnxSource(source) else {
      throw LocalModelError.invalidHuggingFaceModel
    }
    return source
  }
  #endif

  private static func validatedSource(repoID: String, modelName: String) throws -> (String, String) {
    let repoID = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
    let modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard HuggingFaceRepoInput.isValidRepoID(repoID) else {
      throw LocalModelError.invalidHuggingFaceRepo(repoID)
    }
    guard !modelName.isEmpty else {
      throw LocalModelError.invalidHuggingFaceModel
    }
    return (repoID, modelName)
  }

  static func deduplicateModels(_ models: [LocalTranscriptionModel]) -> [LocalTranscriptionModel] {
    var seenIDs = Set<String>()
    return models.reversed().compactMap { model in
      guard !seenIDs.contains(model.id) else { return nil }
      seenIDs.insert(model.id)
      return model
    }.reversed()
  }
}
