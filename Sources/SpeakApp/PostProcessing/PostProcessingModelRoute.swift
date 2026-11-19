import SpeakCore
import Foundation

/// Where a configured post-processing model runs. One classification shared by
/// the session path, the Polish Text intent, the key check and Settings, so
/// they can never disagree about whether a model is local.
enum PostProcessingModelRoute: Equatable {
  /// Apple Intelligence's on-device Foundation model.
  case appleFoundation
  /// The deterministic rules cleaner; it cannot follow a prompt.
  case builtInRules
  /// A downloaded GGUF model run by the local llama.cpp runtime.
  case downloaded
  /// Any other identifier, sent to the configured chat client.
  case remote

  init(model: String) {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == AppleLocalModels.foundationModelID {
      self = .appleFoundation
    } else if trimmed.lowercased() == LocalPostProcessingModelManager.builtInRulesModelID {
      self = .builtInRules
    } else if LocalPostProcessingModelManager.isDownloadedLocalModelID(trimmed) {
      self = .downloaded
    } else {
      self = .remote
    }
  }

  var isLocal: Bool {
    self != .remote
  }
}
