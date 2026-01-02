import Combine
import Foundation

// @Implement: This file is the state manager for the Heads-Up display. It exposes lifecycle functions so that another class can notify it when recording has started, transcribing has started, post-processing has started, etc. It has an enum for all the states it can be in and is a state machine. It also has the ability to surface errors in any of those things and it has an internal timer that shows the duration of each step.

@MainActor
final class HUDManager: ObservableObject {
  struct Snapshot: Equatable {
    enum Phase: Equatable {
      case hidden
      case recording
      case transcribing
      case postProcessing
      case delivering
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

    var phase: Phase
    var headline: String
    var subheadline: String?
    var elapsed: TimeInterval
    var liveText: String?
    var liveTextIsFinal: Bool
    var liveTextConfidence: Double?
    var streamingText: String?
    var finalTranscript: String
    var interimTranscript: String

    static let hidden = Snapshot(
      phase: .hidden, headline: "", subheadline: nil, elapsed: 0,
      liveText: nil, liveTextIsFinal: true, liveTextConfidence: nil, streamingText: nil,
      finalTranscript: "", interimTranscript: ""
    )
  }

  /// Threshold for auto-expanding HUD when transcript exceeds this character count
  static let autoExpandThreshold = 100

  /// Whether the HUD is in expanded mode showing full transcript
  @Published var isExpanded: Bool = false

  @Published private(set) var snapshot: Snapshot = .hidden
  /// Normalized audio level (0.0 to 1.0) during recording phase
  @Published private(set) var audioLevel: Float = 0

  private var timer: Timer?
  private var phaseStartDate: Date?
  private var autoHideTimer: Timer?

  func beginRecording() {
    isExpanded = false
    transition(.recording, headline: "Recording", subheadline: "Capturing audio")
  }

  /// Update the current audio level during recording (0.0 to 1.0)
  func updateAudioLevel(_ level: Float) {
    guard case .recording = snapshot.phase else { return }
    audioLevel = level
  }

  func beginTranscribing() {
    audioLevel = 0
    transition(.transcribing, headline: "Transcribing", subheadline: "Preparing raw transcript")
  }

  func beginPostProcessing() {
    transition(.postProcessing, headline: "Post-processing", subheadline: "Cleaning up transcript")
  }

  func updateStreamingText(_ text: String) {
    snapshot.streamingText = text
  }

  func beginDelivering() {
    transition(.delivering, headline: "Delivering", subheadline: "Pasting into target app")
  }

  func finishSuccess(message: String) {
    transition(
      .success(message: message), headline: "Completed", subheadline: message, showsTimer: false)
    scheduleAutoHide(after: 2.4)
  }

  func finishFailure(message: String) {
    finishFailure(headline: "Something went wrong", message: message)
  }

  func finishFailure(headline: String, message: String, displayDuration: TimeInterval = 6.0) {
    transition(
      .failure(message: message), headline: headline, subheadline: message, showsTimer: false)
    scheduleAutoHide(after: displayDuration)
  }

  func hide() {
    invalidateTimers()
    audioLevel = 0
    snapshot = .hidden
  }

  private func transition(
    _ phase: Snapshot.Phase,
    headline: String,
    subheadline: String?,
    showsTimer: Bool = true
  ) {
    invalidateTimers()
    phaseStartDate = showsTimer ? Date() : nil
    snapshot = Snapshot(
      phase: phase, headline: headline, subheadline: subheadline, elapsed: 0,
      liveText: nil, liveTextIsFinal: true, liveTextConfidence: nil, streamingText: nil,
      finalTranscript: "", interimTranscript: ""
    )

    guard showsTimer else { return }

    timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let start = self.phaseStartDate else { return }
        let elapsed = Date().timeIntervalSince(start)
        self.snapshot.elapsed = elapsed
      }
    }
    if let timer {
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  private func scheduleAutoHide(after delay: TimeInterval) {
    autoHideTimer?.invalidate()
    guard delay > 0 else { return }
    autoHideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        defer { self.autoHideTimer = nil }
        guard self.snapshot.phase.isTerminal else { return }
        self.hide()
      }
    }
    if let autoHideTimer {
      RunLoop.main.add(autoHideTimer, forMode: .common)
    }
  }

  private func invalidateTimers() {
    timer?.invalidate()
    timer = nil
    autoHideTimer?.invalidate()
    autoHideTimer = nil
  }
}
// @Implement: This file is the state manager for the Heads-Up display. It exposes lifecycle functions so that another class can notify it when recording has started, transcribing has started, post-processing has started, etc. It has an enum for all the states it can be in and is a state machine. It also has the ability to surface errors in any of those things and it has an internal timer that shows the duration of each step.
