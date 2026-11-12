import Foundation
import SpeakCore

// Identity and migration rules are canonical in SpeakCore; these forwarders
// keep existing macOS call sites unchanged.
extension LocalModelManager {
  nonisolated static func huggingFaceModelID(repoID: String, modelName: String) -> String {
    WhisperKitHuggingFaceModels.modelID(repoID: repoID, modelName: modelName)
  }

  nonisolated static func normalizedLocalModelID(_ identifier: String) -> String {
    WhisperKitHuggingFaceModels.normalizedModelID(identifier)
  }

  nonisolated static func normalizedImportedModel(_ model: LocalTranscriptionModel) -> LocalTranscriptionModel {
    WhisperKitHuggingFaceModels.normalizedImportedModel(model)
  }

  #if !APP_STORE
  nonisolated static func normalizedStreamingModelSource(
    _ source: LocalStreamingModelSource
  ) -> LocalStreamingModelSource {
    LocalStreamingModelSource.normalized(source)
  }
  #endif

  nonisolated static func slug(_ value: String) -> String {
    LocalModelIdentity.slug(value)
  }

  #if !APP_STORE
  nonisolated static func streamingRuntimeHint(for repoID: String, modelName: String) -> String {
    LocalStreamingModelSource.runtimeHint(repoID: repoID, modelName: modelName)
  }

  nonisolated static func streamingApproximateSizeMB(repoID: String, modelName: String) -> Int? {
    LocalStreamingModelSource.knownApproximateSizeMB(repoID: repoID, modelName: modelName)
  }

  nonisolated static func isSupportedStreamingSource(_ source: LocalStreamingModelSource) -> Bool {
    LocalStreamingModelSource.isRunnableSherpaOnnxSource(source)
  }
  #endif

  nonisolated static func resolveHuggingFaceModel(repoID: String, modelName: String) -> ResolvedHuggingFaceModel {
    WhisperKitHuggingFaceModels.resolve(repoID: repoID, modelName: modelName)
  }
}
