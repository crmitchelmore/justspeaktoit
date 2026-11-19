import Foundation

enum HUDPhase: Equatable {
  case hidden
  /// Hands-free dictation is armed: the detector is listening, but nothing
  /// is being captured until the user speaks.
  case armed
  case recording
  case transcribing
  case postProcessing
  case delivering
  case editing
  case success(message: String)
  case failure(message: String)

  var isTerminal: Bool {
    switch self {
    case .success, .failure:
      return true
    default:
      return false
    }
  }

  var isVisible: Bool {
    self != .hidden
  }
}
