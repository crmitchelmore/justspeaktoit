import Foundation

#if !APP_STORE
enum LocalPostProcessingModelError: LocalizedError {
  case pythonUnavailable
  case runtimeUnavailable(String)
  case unknownModel(String)
  case modelNotInstalled(String)
  case invalidHuggingFaceSource(String)
  case downloadFailed(String)
  case processFailed(String)

  var errorDescription: String? {
    switch self {
    case .pythonUnavailable:
      return "Python 3 was not found. Install Python 3 to enable downloaded local post-processing models."
    case .runtimeUnavailable(let details):
      return "llama.cpp local post-processing runtime is not installed. \(details)"
    case .unknownModel(let model):
      return "Unknown local post-processing model: \(model)"
    case .modelNotInstalled(let model):
      return "\(model) has not been downloaded yet. Download it in Settings > Post-processing > Local."
    case .invalidHuggingFaceSource(let details):
      return "Enter a valid Hugging Face GGUF model source. \(details)"
    case .downloadFailed(let details):
      return "Could not download the local post-processing model from Hugging Face. \(details)"
    case .processFailed(let details):
      return "Local post-processing failed. \(details)"
    }
  }
}
#endif
