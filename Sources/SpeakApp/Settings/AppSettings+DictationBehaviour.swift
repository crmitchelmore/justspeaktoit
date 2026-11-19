import Foundation
import SpeakCore

/// How dictation is triggered, stopped and delivered: hotkey gestures, silence
/// handling, voice commands, corrections and the insertion path.
@MainActor
final class DictationBehaviourPreferences: ObservableObject {
  private let persistence: AppSettingsPersistence

  @Published var hotKeyActivationStyle: AppSettings.HotKeyActivationStyle {
    didSet { persistence.store(hotKeyActivationStyle.rawValue, key: .hotKeyActivation) }
  }

  @Published var holdThreshold: TimeInterval {
    didSet { persistence.store(holdThreshold, key: .holdThreshold) }
  }

  @Published var doubleTapWindow: TimeInterval {
    didSet { persistence.store(doubleTapWindow, key: .doubleTapWindow) }
  }

  @Published var silenceDetectionEnabled: Bool {
    didSet { persistence.store(silenceDetectionEnabled, key: .silenceDetectionEnabled) }
  }

  /// Silence threshold (0.0 to 1.0) - audio levels below this are considered silence
  @Published var silenceThreshold: Float {
    didSet { persistence.store(Double(silenceThreshold), key: .silenceThreshold) }
  }

  /// Duration of continuous silence (in seconds) before auto-stopping
  @Published var silenceDuration: TimeInterval {
    didSet { persistence.store(silenceDuration, key: .silenceDuration) }
  }

  @Published var historyFlushInterval: TimeInterval {
    didSet { persistence.store(historyFlushInterval, key: .historyFlushInterval) }
  }

  @Published var voiceCommandsEnabled: Bool {
    didSet { persistence.store(voiceCommandsEnabled, key: .voiceCommandsEnabled) }
  }

  /// Custom triggers for clipboard insertion (comma-separated), in addition to built-in triggers
  @Published var clipboardInsertionTriggers: String {
    didSet { persistence.store(clipboardInsertionTriggers, key: .clipboardInsertionTriggers) }
  }

  /// Enable automatic detection of user corrections after transcription
  @Published var autoCorrectionsEnabled: Bool {
    didSet { persistence.store(autoCorrectionsEnabled, key: .autoCorrectionsEnabled) }
  }

  /// Number of times a correction must be seen before auto-promoting to a rule
  @Published var autoCorrectionsPromotionThreshold: Int {
    didSet { persistence.store(autoCorrectionsPromotionThreshold, key: .autoCorrectionsPromotionThreshold) }
  }

  /// Whether a cancelled recording's audio stays in History to transcribe later.
  @Published var keepAudioOnCancel: Bool {
    didSet { persistence.store(keepAudioOnCancel, key: .keepAudioOnCancel) }
  }

  @Published var accessibilityInsertionMode: AppSettings.AccessibilityInsertionMode {
    didSet { persistence.store(accessibilityInsertionMode.rawValue, key: .accessibilityInsertionMode) }
  }

  @Published var restoreClipboardAfterPaste: Bool {
    didSet { persistence.store(restoreClipboardAfterPaste, key: .restoreClipboard) }
  }

  init(persistence: AppSettingsPersistence) {
    self.persistence = persistence
    let defaults = persistence.defaults
    hotKeyActivationStyle = persistence.choice(.hotKeyActivation, default: .holdAndDoubleTap)
    holdThreshold = persistence.number(.holdThreshold, default: 0.35)
    doubleTapWindow = persistence.number(.doubleTapWindow, default: 0.4)
    silenceDetectionEnabled = persistence.flag(.silenceDetectionEnabled, default: false)
    silenceThreshold = Float(persistence.number(.silenceThreshold, default: DictationSilencePolicy.defaultThreshold))
    silenceDuration = persistence.number(.silenceDuration, default: DictationSilencePolicy.defaultDuration)
    historyFlushInterval = persistence.number(.historyFlushInterval, default: 5.0)
    voiceCommandsEnabled = persistence.flag(.voiceCommandsEnabled, default: SpeechDefaults.voiceCommandsEnabled)
    clipboardInsertionTriggers =
      defaults.string(forKey: ApplicationPreferenceKey.clipboardInsertionTriggers.rawValue)
      ?? SpeechDefaults.clipboardInsertionTriggers
    autoCorrectionsEnabled =
      persistence.flag(.autoCorrectionsEnabled, default: AutoCorrectionLearningPolicy.enabledByDefault)
    autoCorrectionsPromotionThreshold = persistence.integer(
      .autoCorrectionsPromotionThreshold, default: AutoCorrectionLearningPolicy.defaultPromotionThreshold
    )
    keepAudioOnCancel = SharedApplicationPreferences.keepAudioOnCancel.macOS.value(in: defaults)
    accessibilityInsertionMode = persistence.choice(.accessibilityInsertionMode, default: .insertAtCursor)
    restoreClipboardAfterPaste = persistence.flag(.restoreClipboard, default: true)
  }

  func reload(from restored: DictationBehaviourPreferences) {
    hotKeyActivationStyle = restored.hotKeyActivationStyle
    holdThreshold = restored.holdThreshold
    doubleTapWindow = restored.doubleTapWindow
    silenceDetectionEnabled = restored.silenceDetectionEnabled
    silenceThreshold = restored.silenceThreshold
    silenceDuration = restored.silenceDuration
    historyFlushInterval = restored.historyFlushInterval
    voiceCommandsEnabled = restored.voiceCommandsEnabled
    clipboardInsertionTriggers = restored.clipboardInsertionTriggers
    autoCorrectionsEnabled = restored.autoCorrectionsEnabled
    autoCorrectionsPromotionThreshold = restored.autoCorrectionsPromotionThreshold
    keepAudioOnCancel = restored.keepAudioOnCancel
    accessibilityInsertionMode = restored.accessibilityInsertionMode
    restoreClipboardAfterPaste = restored.restoreClipboardAfterPaste
  }
}

extension AppSettings {
  var hotKeyActivationStyle: HotKeyActivationStyle {
    get { dictationBehaviour.hotKeyActivationStyle }
    set { dictationBehaviour.hotKeyActivationStyle = newValue }
  }

  var holdThreshold: TimeInterval {
    get { dictationBehaviour.holdThreshold }
    set { dictationBehaviour.holdThreshold = newValue }
  }

  var doubleTapWindow: TimeInterval {
    get { dictationBehaviour.doubleTapWindow }
    set { dictationBehaviour.doubleTapWindow = newValue }
  }

  var silenceDetectionEnabled: Bool {
    get { dictationBehaviour.silenceDetectionEnabled }
    set { dictationBehaviour.silenceDetectionEnabled = newValue }
  }

  var silenceThreshold: Float {
    get { dictationBehaviour.silenceThreshold }
    set { dictationBehaviour.silenceThreshold = newValue }
  }

  var silenceDuration: TimeInterval {
    get { dictationBehaviour.silenceDuration }
    set { dictationBehaviour.silenceDuration = newValue }
  }

  var historyFlushInterval: TimeInterval {
    get { dictationBehaviour.historyFlushInterval }
    set { dictationBehaviour.historyFlushInterval = newValue }
  }

  var voiceCommandsEnabled: Bool {
    get { dictationBehaviour.voiceCommandsEnabled }
    set { dictationBehaviour.voiceCommandsEnabled = newValue }
  }

  var clipboardInsertionTriggers: String {
    get { dictationBehaviour.clipboardInsertionTriggers }
    set { dictationBehaviour.clipboardInsertionTriggers = newValue }
  }

  var autoCorrectionsEnabled: Bool {
    get { dictationBehaviour.autoCorrectionsEnabled }
    set { dictationBehaviour.autoCorrectionsEnabled = newValue }
  }

  var autoCorrectionsPromotionThreshold: Int {
    get { dictationBehaviour.autoCorrectionsPromotionThreshold }
    set { dictationBehaviour.autoCorrectionsPromotionThreshold = newValue }
  }

  var keepAudioOnCancel: Bool {
    get { dictationBehaviour.keepAudioOnCancel }
    set { dictationBehaviour.keepAudioOnCancel = newValue }
  }

  var accessibilityInsertionMode: AccessibilityInsertionMode {
    get { dictationBehaviour.accessibilityInsertionMode }
    set { dictationBehaviour.accessibilityInsertionMode = newValue }
  }

  var restoreClipboardAfterPaste: Bool {
    get { dictationBehaviour.restoreClipboardAfterPaste }
    set { dictationBehaviour.restoreClipboardAfterPaste = newValue }
  }
}
