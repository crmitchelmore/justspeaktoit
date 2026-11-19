import Foundation
import SpeakCore
import class WhisperKit.WhisperKit
import class WhisperKit.WhisperKitConfig

/// The loaded WhisperKit pipeline and any in-flight loads. At most one model
/// stays loaded; concurrent requests for the same model share one load.
@MainActor
final class WhisperKitPipelineCache {
  private var activePipelines: [String: WhisperKit] = [:]
  private var loadingPipelines: [String: Task<WhisperKit, Error>] = [:]
  private let modelStorage: WhisperKitModelStorage
  private let pipelineLoader: @MainActor (WhisperKitConfig) async throws -> WhisperKit

  init(
    modelStorage: WhisperKitModelStorage,
    pipelineLoader: @escaping @MainActor (WhisperKitConfig) async throws -> WhisperKit
  ) {
    self.modelStorage = modelStorage
    self.pipelineLoader = pipelineLoader
  }

  func isLoaded(_ modelID: String) -> Bool {
    activePipelines[modelID] != nil
  }

  func isLoading(_ modelID: String) -> Bool {
    loadingPipelines[modelID] != nil
  }

  func evict(_ modelID: String) {
    activePipelines[modelID] = nil
  }

  func pipeline(
    for model: LocalTranscriptionModel, useManagedStorage: Bool = false
  ) async throws -> WhisperKit {
    guard model.engine == .whisperKit else { throw LocalModelError.unknownModel(model.id) }
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
}
