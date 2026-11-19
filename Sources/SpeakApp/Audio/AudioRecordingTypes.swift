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
  /// `systemUptime` at the moment the recorder proved it was capturing, taken
  /// on the recorder's actor so a busy main thread cannot inflate it (#611).
  var liveUptime: TimeInterval?
  /// How long `record()` took to prove capture.
  var recorderOpenMilliseconds: Int?
}

/// Main-actor state a capture start needs, read before the recorder's actor
/// takes over (#611). The HUD panel is presented on the main run loop as a
/// session starts, so each main-actor hop inside `startRecording` used to wait
/// for that render before the microphone could open.
struct CaptureStartPreflight: Sendable {
  let microphoneGranted: Bool
  let recordingsDirectory: URL
  /// The preferred-input session, begun only when the microphone is granted.
  /// `startRecording(preflight:)` owns it from then on and ends it on failure.
  let inputSession: AudioInputDeviceManager.SessionContext?
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
