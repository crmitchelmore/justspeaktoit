import Foundation
import SpeakCore

/// Presentation and recording feedback: layout density, the HUD, sidebar hints
/// and recording sounds.
@MainActor
final class FeedbackPreferences: ObservableObject {
  private let persistence: AppSettingsPersistence

  @Published var visualDensity: AppVisualDensity {
    didSet { persistence.store(visualDensity.rawValue, key: .visualDensity) }
  }

  @Published var showHUDDuringSessions: Bool {
    didSet { persistence.store(showHUDDuringSessions, key: .showHUD) }
  }

  @Published var showLiveTranscriptInHUD: Bool {
    didSet { persistence.store(showLiveTranscriptInHUD, key: .showLiveTranscriptInHUD) }
  }

  /// When on, the HUD is drawn in its compact form (a pulsing dot, a live level
  /// meter and the timer). It stands alongside `showLiveTranscriptInHUD`, which
  /// still governs whether the scrolling transcript line is drawn: the compact
  /// HUD can run with the live transcript on or off, independently.
  @Published var showCompactHUD: Bool {
    didSet { persistence.store(showCompactHUD, key: .showCompactHUD) }
  }

  /// When on, a failure or cancellation message auto-hides after
  /// `HUDManager.shortFailureDisplayDuration` instead of the standard
  /// `HUDManager.standardFailureDisplayDuration`. Success messages are
  /// unaffected - only the failure/cancellation duration shortens.
  @Published var shortenErrorDisplay: Bool {
    didSet { persistence.store(shortenErrorDisplay, key: .shortenErrorDisplay) }
  }

  @Published var showSidebarShortcutHints: Bool {
    didSet { persistence.store(showSidebarShortcutHints, key: .showSidebarShortcutHints) }
  }

  @Published var hudSizePreference: HUDExpansionPreference {
    didSet { persistence.store(hudSizePreference.rawValue, key: .hudSizePreference) }
  }

  @Published var recordingSoundsEnabled: Bool {
    didSet { persistence.store(recordingSoundsEnabled, key: .recordingSoundsEnabled) }
  }

  /// Volume level for recording sounds (0.0 = silent, 1.0 = full volume)
  @Published var recordingSoundVolume: Float {
    didSet { persistence.store(Double(recordingSoundVolume), key: .recordingSoundVolume) }
  }

  init(persistence: AppSettingsPersistence) {
    self.persistence = persistence
    visualDensity = SharedApplicationPreferences.visualDensity.macOS.value(in: persistence.defaults)
    showHUDDuringSessions = persistence.flag(.showHUD, default: SpeechDefaults.showHUD)
    showLiveTranscriptInHUD = persistence.flag(.showLiveTranscriptInHUD, default: SpeechDefaults.liveTranscriptHUD)
    showCompactHUD = persistence.flag(.showCompactHUD, default: SpeechDefaults.compactHUD)
    shortenErrorDisplay = persistence.flag(.shortenErrorDisplay, default: SpeechDefaults.shortErrors)
    showSidebarShortcutHints = persistence.flag(.showSidebarShortcutHints, default: true)
    hudSizePreference = persistence.choice(.hudSizePreference, default: .defaultValue)
    recordingSoundsEnabled = persistence.flag(.recordingSoundsEnabled, default: RecordingFeedbackDefaults.enabled)
    recordingSoundVolume = Float(persistence.number(.recordingSoundVolume, default: RecordingFeedbackDefaults.volume))
  }

  func reload(from restored: FeedbackPreferences) {
    visualDensity = restored.visualDensity
    showHUDDuringSessions = restored.showHUDDuringSessions
    showLiveTranscriptInHUD = restored.showLiveTranscriptInHUD
    showCompactHUD = restored.showCompactHUD
    shortenErrorDisplay = restored.shortenErrorDisplay
    showSidebarShortcutHints = restored.showSidebarShortcutHints
    hudSizePreference = restored.hudSizePreference
    recordingSoundsEnabled = restored.recordingSoundsEnabled
    recordingSoundVolume = restored.recordingSoundVolume
  }
}

extension AppSettings {
  var visualDensity: AppVisualDensity {
    get { feedback.visualDensity }
    set { feedback.visualDensity = newValue }
  }

  var showHUDDuringSessions: Bool {
    get { feedback.showHUDDuringSessions }
    set { feedback.showHUDDuringSessions = newValue }
  }

  var showLiveTranscriptInHUD: Bool {
    get { feedback.showLiveTranscriptInHUD }
    set { feedback.showLiveTranscriptInHUD = newValue }
  }

  var showCompactHUD: Bool {
    get { feedback.showCompactHUD }
    set { feedback.showCompactHUD = newValue }
  }

  var shortenErrorDisplay: Bool {
    get { feedback.shortenErrorDisplay }
    set { feedback.shortenErrorDisplay = newValue }
  }

  var showSidebarShortcutHints: Bool {
    get { feedback.showSidebarShortcutHints }
    set { feedback.showSidebarShortcutHints = newValue }
  }

  var hudSizePreference: HUDSizePreference {
    get { feedback.hudSizePreference }
    set { feedback.hudSizePreference = newValue }
  }

  var recordingSoundsEnabled: Bool {
    get { feedback.recordingSoundsEnabled }
    set { feedback.recordingSoundsEnabled = newValue }
  }

  var recordingSoundVolume: Float {
    get { feedback.recordingSoundVolume }
    set { feedback.recordingSoundVolume = newValue }
  }
}
