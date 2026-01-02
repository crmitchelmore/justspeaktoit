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
    var showRetryHint: Bool

    static let hidden = Snapshot(phase: .hidden, headline: "", subheadline: nil, elapsed: 0, showRetryHint: false)
  }

  /// Threshold for auto-expanding HUD when transcript exceeds this character count
  static let autoExpandThreshold = 100

  /// Whether the HUD is in expanded mode showing full transcript
  @Published var isExpanded: Bool = false

  @Published private(set) var snapshot: Snapshot = .hidden

  private var timer: Timer?
  private var phaseStartDate: Date?
  private var autoHideTimer: Timer?

  func beginRecording() {
    isExpanded = false
    transition(.recording, headline: "Recording", subheadline: "Capturing audio")
  }

  func updateLiveTranscription(text: String, isFinal: Bool, confidence: Double?) {
    guard snapshot.phase == .recording else { return }
    snapshot.liveText = text.isEmpty ? nil : text
    snapshot.liveTextIsFinal = isFinal
    snapshot.liveTextConfidence = confidence
  }

  func updateLiveTranscript(final: String, interim: String) {
    snapshot.finalTranscript = final
    snapshot.interimTranscript = interim
    // Auto-expand if transcript exceeds threshold
    let totalLength = final.count + interim.count
    if totalLength > Self.autoExpandThreshold && !isExpanded {
      isExpanded = true
    }
  }

  func toggleExpanded() {
    isExpanded.toggle()
  }

  func beginTranscribing() {
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
    finishFailure(headline: "Something went wrong", message: message, showRetryHint: false)
  }

  func finishFailure(headline: String, message: String, displayDuration: TimeInterval = 6.0) {
    finishFailure(headline: headline, message: message, showRetryHint: false, displayDuration: displayDuration)
  }

  func finishFailure(headline: String, message: String, showRetryHint: Bool, displayDuration: TimeInterval = 6.0) {
    transition(
      .failure(message: message), headline: headline, subheadline: message, showsTimer: false, showRetryHint: showRetryHint)
    scheduleAutoHide(after: displayDuration)
  }

  func hide() {
    invalidateTimers()
    snapshot = .hidden
  }

  private func transition(
    _ phase: Snapshot.Phase,
    headline: String,
    subheadline: String?,
    showsTimer: Bool = true,
    showRetryHint: Bool = false
  ) {
    invalidateTimers()
    phaseStartDate = showsTimer ? Date() : nil
    snapshot = Snapshot(phase: phase, headline: headline, subheadline: subheadline, elapsed: 0, showRetryHint: showRetryHint)

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
