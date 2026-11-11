import Foundation

struct RecordingSummary: Identifiable, Hashable, Sendable {
  let id: UUID
  let url: URL
  let startedAt: Date
  let duration: TimeInterval
  let fileSize: Int64
}

enum AudioRecordingOwner: Sendable {
  case dictation
  case auxiliary
  /// A Voice Edit instruction recording. Reported to the warm coordinator like
  /// any auxiliary capture, but identified so dictation's failure cleanup can
  /// never cancel it (issue #673).
  case voiceEdit
}

enum AudioRecordingLifecycleEvent: Sendable {
  case auxiliaryStarted
  case auxiliaryEnded
}

struct RecordingStart: Sendable {
  let url: URL
  let usedWarmRecorder: Bool
}

enum AudioFileManagerError: LocalizedError {
  case alreadyRecording
  case noActiveRecording
  case microphonePermissionMissing
  case failedToConfigureSession
  case failedToCreateRecorder
  case failedToStartCapture

  var errorDescription: String? {
    switch self {
    case .alreadyRecording:
      return "A recording session is already active."
    case .noActiveRecording:
      return "No active recording session is running."
    case .microphonePermissionMissing:
      return "Microphone permission has not been granted."
    case .failedToConfigureSession:
      return "Failed to configure the audio session."
    case .failedToCreateRecorder:
      return "Could not create the audio recorder."
    case .failedToStartCapture:
      return "The microphone did not start capturing. Check the input device and try again."
    }
  }
}
