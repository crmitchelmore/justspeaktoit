import AppKit
import Combine
import Foundation

// @Implement: This file is the state manager for the Heads-Up display. It exposes lifecycle functions so that another class can notify it when recording has started, transcribing has started, post-processing has started, etc. It has an enum for all the states it can be in and is a state machine. It also has the ability to surface errors in any of those things and it has an internal timer that shows the duration of each step.

@MainActor
final class HUDManager: ObservableObject {
  struct Snapshot: Equatable {
    enum Phase: Equatable {
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
  /// Current capture-health data shown in the HUD during recording and failure phases.
  @Published private(set) var captureHealth: CaptureHealthSnapshot = .empty
  /// Normalized audio level (0.0 to 1.0) during recording phase
  @Published private(set) var audioLevel: Float = 0

  private let appSettings: AppSettings
  private let accessibilityAnnouncementPoster: ((String) -> Void)?
  private var timer: Timer?
  private var phaseStartDate: Date?
  private var autoHideTimer: Timer?
  /// The interval most recently passed to `scheduleAutoHide`. `Timer.timeInterval`
  /// reads back as 0 for a non-repeating timer, so this is the only way to
  /// observe which duration a `finishSuccess`/`finishFailure` call actually
  /// scheduled - test-only visibility, never read by production code.
  private(set) var lastScheduledAutoHideDuration: TimeInterval?

  init(
    appSettings: AppSettings,
    accessibilityAnnouncementPoster: ((String) -> Void)? = nil
  ) {
    self.appSettings = appSettings
    self.accessibilityAnnouncementPoster = accessibilityAnnouncementPoster
  }

  static func accessibilityAnnouncement(
    for phase: Snapshot.Phase,
    subheadline: String?
  ) -> String? {
    let detail = subheadline.map { ". \($0)" } ?? ""
    switch phase {
    case .armed:
      return "Hands-free dictation armed\(detail)"
    case .recording:
      return "Recording started\(detail)"
    case .transcribing:
      return "Transcribing\(detail)"
    case .postProcessing:
      return "Post-processing\(detail)"
    case .delivering:
      return "Delivering transcription\(detail)"
    case .editing:
      return "Editing\(detail)"
    case .success(let message):
      return "Success. \(message)"
    case .failure(let message):
      return "Failed. \(message)"
    case .hidden:
      return nil
    }
  }

  /// Begins the recording phase. When a dictation profile is active for the
  /// session, its name is surfaced in the HUD subheadline.
  func beginRecording(profileName: String? = nil) {
    // Set initial expansion state based on user preference
    switch appSettings.hudSizePreference {
    case .compact:
      isExpanded = false
    case .expanded:
      isExpanded = true
    case .autoExpand:
      isExpanded = false  // Will auto-expand when transcript exceeds threshold
    }
    let subheadline = profileName.map { "Profile: \($0)" } ?? "Capturing audio"
    transition(.recording, headline: "Recording", subheadline: subheadline)
  }

  /// Shows the armed indicator for hands-free dictation. The HUD stays up
  /// between utterances so "armed but silent" is never mistaken for "off".
  func beginArmed(subheadline: String = "Hands-free dictation is armed") {
    transition(
      .armed,
      headline: "Listening for speech",
      subheadline: subheadline,
      showsTimer: false
    )
  }

  /// Update the current audio level during recording (0.0 to 1.0)
  func updateAudioLevel(_ level: Float) {
    guard case .recording = snapshot.phase else { return }
    audioLevel = level
  }

  /// Update live transcription text, final state, and confidence
  func updateLiveTranscription(text: String, isFinal: Bool, confidence: Double?) {
    guard snapshot.phase == .recording || snapshot.phase == .editing else { return }
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

  func beginTranscribing(subheadline: String = "Preparing raw transcript") {
    audioLevel = 0
    transition(.transcribing, headline: "Transcribing", subheadline: subheadline)
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

  /// Voice-edit mode: a distinct "Editing" state reused across its listening, rewriting, and
  /// applying stages (the subheadline tells them apart).
  func beginEditing(subheadline: String) {
    transition(.editing, headline: "Editing", subheadline: subheadline)
  }

  /// How long a success confirmation stays on screen before it auto-hides.
  static let successDisplayDuration: TimeInterval = 2.4

  /// The default interval a failure or cancellation message stays on screen.
  static let standardFailureDisplayDuration: TimeInterval = 6.0

  /// The interval used when the "Shorten error display" preference is on -
  /// 50% longer than `successDisplayDuration`, so a failure still reads as
  /// slower than a success without lingering nearly 3x as long.
  static let shortFailureDisplayDuration: TimeInterval = 3.6

  /// Resolves the auto-hide interval for a failure/cancellation message from
  /// the "Shorten error display" preference. A caller-supplied
  /// `displayDuration` (eg the 3s "voice edit in progress" refusal) always
  /// wins - the preference only changes the shared default the other
  /// `finishFailure` call sites fall back to.
  static func failureDisplayDuration(shortenErrorDisplay: Bool) -> TimeInterval {
    shortenErrorDisplay ? shortFailureDisplayDuration : standardFailureDisplayDuration
  }

  func finishSuccess(message: String) {
    transition(
      .success(message: message), headline: "Completed", subheadline: message, showsTimer: false)
    scheduleAutoHide(after: Self.successDisplayDuration)
  }

  func finishFailure(message: String) {
    finishFailure(headline: "Something went wrong", message: message, showRetryHint: false)
  }

  func finishFailure(headline: String, message: String, displayDuration: TimeInterval? = nil) {
    finishFailure(headline: headline, message: message, showRetryHint: false, displayDuration: displayDuration)
  }

  func finishFailure(headline: String, message: String, showRetryHint: Bool, displayDuration: TimeInterval? = nil) {
    transition(
      .failure(message: message), headline: headline, subheadline: message, showsTimer: false, showRetryHint: showRetryHint)
    let resolvedDuration = displayDuration
      ?? Self.failureDisplayDuration(shortenErrorDisplay: appSettings.shortenErrorDisplay)
    scheduleAutoHide(after: resolvedDuration)
  }

  func hide() {
    guard snapshot.phase.isVisible else { return }
    invalidateTimers()
    audioLevel = 0
    snapshot = .hidden
    postAccessibilityAnnouncement("HUD dismissed")
  }

  func updateCaptureHealth(_ health: CaptureHealthSnapshot) {
    captureHealth = health
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
    if let announcement = Self.accessibilityAnnouncement(for: phase, subheadline: subheadline) {
      postAccessibilityAnnouncement(announcement)
    }

    guard showsTimer else { return }

    // Use target-selector Timer pattern to completely bypass Swift concurrency runtime.
    // Block-based timers with [weak self] can crash in swift_getObjectType during
    // executor verification if the object is deallocating.
    timer = Timer.scheduledTimer(
      timeInterval: HUDPlatformWorkarounds.elapsedTimerInterval,
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
    lastScheduledAutoHideDuration = delay
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

  private func postAccessibilityAnnouncement(_ announcement: String) {
    if let accessibilityAnnouncementPoster {
      accessibilityAnnouncementPoster(announcement)
      return
    }
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
      .announcement: announcement,
      .priority: NSAccessibilityPriorityLevel.high.rawValue
    ])
  }
}
// @Implement: This file is the state manager for the Heads-Up display. It exposes lifecycle functions so that another class can notify it when recording has started, transcribing has started, post-processing has started, etc. It has an enum for all the states it can be in and is a state machine. It also has the ability to surface errors in any of those things and it has an internal timer that shows the duration of each step.
