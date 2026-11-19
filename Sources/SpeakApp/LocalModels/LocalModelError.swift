import Foundation
import SpeakCore

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
    case .unknownModel(let model)
    where model == PhononLocalModels.phonon2.id && !PhononLocalModels.isSupportedOnCurrentPlatform:
      // A selection carried over from the direct-download Apple silicon app.
      return "Phonon-2 needs the direct-download app on an Apple silicon Mac. "
        + "Choose another model in Settings > Transcription > Local Models."
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
