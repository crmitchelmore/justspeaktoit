import SwiftUI

/// Shared accessibility semantics for every control that toggles recording.
///
/// Centralises the label, hint and trait derivation so the Dashboard buttons
/// and the MainView toolbar control cannot drift apart. Labels are
/// action-oriented (what activation does), independent of the visible status
/// copy, and `.startsMediaSession` is applied only in states where activation
/// begins microphone capture—never when it stops an existing session.
struct RecordingControlAccessibility: Equatable {
  let label: String
  let hint: String
  /// Current recording state, read after the label so VoiceOver reports
  /// whether the control is live (e.g. "Stop recording, Recording").
  let value: String

  /// Whether activating the control begins microphone capture.
  let beginsCapture: Bool

  var traits: AccessibilityTraits {
    beginsCapture ? [.isButton, .startsMediaSession] : .isButton
  }

  @MainActor
  init(state: MainManager.State) {
    switch state {
    case .idle, .completed, .failed:
      label = "Start recording"
      value = "Not recording"
      hint = "Starts a new recording"
      beginsCapture = true
    case .recording:
      label = "Stop recording"
      value = "Recording"
      hint = "Stops recording and processes the transcription"
      beginsCapture = false
    case .processing:
      label = "Processing recording"
      value = "Processing"
      hint = ""
      beginsCapture = false
    case .delivering:
      label = "Delivering transcription"
      value = "Delivering"
      hint = ""
      beginsCapture = false
    }
  }
}
