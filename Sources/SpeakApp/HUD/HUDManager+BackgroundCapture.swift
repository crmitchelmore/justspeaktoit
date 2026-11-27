import Foundation
import SpeakCore

/// Which HUD surface `HUDWindowPresenter` shows while a session is visible.
enum HUDPresentationMode: Equatable, Sendable {
  /// The standard bottom-center full or compact dictation HUD.
  case standard
  /// A subtle, clickable top-right floating pill for system/call audio capture.
  case backgroundPill(source: AudioCaptureSource)

  var isBackgroundPill: Bool {
    if case .backgroundPill = self { return true }
    return false
  }

  var backgroundSource: AudioCaptureSource? {
    if case .backgroundPill(let source) = self { return source }
    return nil
  }
}

extension AudioCaptureSource {
  var backgroundHUDLabel: String {
    switch self {
    case .system: "System Audio"
    case .both: "Call Audio"
    case .mic: "Recording"
    }
  }

  var backgroundHUDStatus: String {
    switch self {
    case .system: "Capturing system audio"
    case .both: "Capturing mic + system audio"
    case .mic: "Capturing microphone"
    }
  }
}

extension HUDManager {
  /// Presents the subtle top-right floating pill for system/call audio capture
  /// instead of the full dictation HUD. The clock starts immediately because
  /// remote/system audio may begin silent before anyone speaks.
  func beginBackgroundRecording(source: AudioCaptureSource) {
    presentationMode = .backgroundPill(source: source)
    isExpanded = false
    transition(
      .recording,
      headline: source.backgroundHUDLabel,
      subheadline: source.backgroundHUDStatus,
      showsTimer: true
    )
  }

  /// Invokes the registered stop handler when the user clicks Stop in the
  /// background capture pill.
  func requestStop() {
    onStopRequested?()
  }
}
