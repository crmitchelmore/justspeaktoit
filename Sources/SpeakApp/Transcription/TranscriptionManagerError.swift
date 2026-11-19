import Foundation

enum TranscriptionManagerError: LocalizedError, Equatable {
  case liveSessionAlreadyRunning
  case liveSessionAlreadyStopping
  case liveSessionNotRunning
  case recognizerUnavailable
  case permissionsMissing
  case microphonePermissionMissing
  case localLiveStreamingUnsupported
  case localLiveStreamingStartupTimedOut
  case invalidLocalStreamingSource(String)
  case noUsableAudioInput

  var errorDescription: String? {
    switch self {
    case .liveSessionAlreadyRunning:
      return "A live transcription session is already running."
    case .liveSessionAlreadyStopping:
      return "A live transcription session is already stopping."
    case .liveSessionNotRunning:
      return "No live transcription session is currently running."
    case .recognizerUnavailable:
      return "The speech recogniser could not be configured for the selected locale."
    case .permissionsMissing:
      return "Required microphone or speech recognition permissions are missing."
    case .microphonePermissionMissing:
      return "Microphone permission is missing. Grant microphone access in System Settings and try again."
    case .localLiveStreamingUnsupported:
      return "The selected downloaded model does not support Local Streaming. Choose another model or use Local Batch."
    case .localLiveStreamingStartupTimedOut:
      return "The local streaming model did not start receiving microphone audio in time. " +
        "Try reconnecting the input device."
    case .invalidLocalStreamingSource(let sourceID):
      return "Local streaming source is not available: \(sourceID). " +
        "Choose or download a local streaming model in Settings."
    case .noUsableAudioInput:
      return "The selected microphone is unavailable. Pick a different input device in Settings and try again."
    }
  }
}
