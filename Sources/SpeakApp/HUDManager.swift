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
    var liveText: String?
    var liveTextIsFinal: Bool
    var liveTextConfidence: Double?
    var streamingText: String?
    var finalTranscript: String
    var interimTranscript: String

    static let hidden = Snapshot(
      phase: .hidden, headline: "", subheadline: nil, elapsed: 0, showRetryHint: false,
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

  private let appSettings: AppSettings
  private var timer: Timer?
  private var phaseStartDate: Date?
  private var autoHideTimer: Timer?

  init(appSettings: AppSettings) {
    self.appSettings = appSettings
  }

  func beginRecording() {
    // Set initial expansion state based on user preference
    switch appSettings.hudSizePreference {
    case .compact:
      isExpanded = false
    case .expanded:
      isExpanded = true
    case .autoExpand:
      isExpanded = false  // Will auto-expand when transcript exceeds threshold
    }
    transition(.recording, headline: "Recording", subheadline: "Capturing audio")
  }

  /// Update the current audio level during recording (0.0 to 1.0)
  func updateAudioLevel(_ level: Float) {
    guard case .recording = snapshot.phase else { return }
    audioLevel = level
  }

  /// Update live transcription text, final state, and confidence
  func updateLiveTranscription(text: String, isFinal: Bool, confidence: Double?) {
    guard snapshot.phase == .recording else { return }
    snapshot.liveText = text.isEmpty ? nil : text
    snapshot.liveTextIsFinal = isFinal
    snapshot.liveTextConfidence = confidence
  }

  func updateLiveTranscript(final: String, interim: String) {
    snapshot.finalTranscript = final
    snapshot.interimTranscript = interim
    // Auto-expand if preference allows and transcript exceeds threshold
    if appSettings.hudSizePreference == .autoExpand {
      let totalLength = final.count + interim.count
      if totalLength > Self.autoExpandThreshold && !isExpanded {
        isExpanded = true
      }
    }
  }

  func toggleExpanded() {
    isExpanded.toggle()
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
    audioLevel = 0
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
    snapshot = Snapshot(
      phase: phase, headline: headline, subheadline: subheadline, elapsed: 0, showRetryHint: showRetryHint,
      liveText: nil, liveTextIsFinal: true, liveTextConfidence: nil, streamingText: nil,
      finalTranscript: "", interimTranscript: ""
    )

    guard showsTimer else { return }

    // Use target-selector Timer pattern to completely bypass Swift concurrency runtime.
    // Block-based timers with [weak self] can crash in swift_getObjectType during
    // executor verification if the object is deallocating.
    timer = Timer.scheduledTimer(
      timeInterval: 0.02,
      target: self,
      selector: #selector(elapsedTimerFired),
      userInfo: nil,
      repeats: true
    )
    if let timer {
      RunLoop.main.add(timer, forMode: .common)
    }
  }
  
  @objc private func elapsedTimerFired() {
    guard let start = phaseStartDate else { return }
    let elapsed = Date().timeIntervalSince(start)
    snapshot.elapsed = elapsed
  }

  private func scheduleAutoHide(after delay: TimeInterval) {
    autoHideTimer?.invalidate()
    guard delay > 0 else { return }
    // Use target-selector Timer pattern to completely bypass Swift concurrency runtime.
    autoHideTimer = Timer.scheduledTimer(
      timeInterval: delay,
      target: self,
      selector: #selector(autoHideTimerFired),
      userInfo: nil,
      repeats: false
    )
    if let autoHideTimer {
      RunLoop.main.add(autoHideTimer, forMode: .common)
    }
  }
  
  @objc private func autoHideTimerFired() {
    defer { autoHideTimer = nil }
    guard snapshot.phase.isTerminal else { return }
    hide()
  }

  private func invalidateTimers() {
    timer?.invalidate()
    timer = nil
    autoHideTimer?.invalidate()
    autoHideTimer = nil
  }
}
// @Implement: This file is the state manager for the Heads-Up display. It exposes lifecycle functions so that another class can notify it when recording has started, transcribing has started, post-processing has started, etc. It has an enum for all the states it can be in and is a state machine. It also has the ability to surface errors in any of those things and it has an internal timer that shows the duration of each step.
