import AppKit
import Combine
import Foundation
import SpeakCore
import SpeakHotKeys
import SwiftUI
import os.log

/// Centralised configuration model backed by `UserDefaults` and published to SwiftUI.
///
/// The preferences that drive transcription selection, the shell and other
/// observers (through their `$` publishers) are published here. Self-contained
/// domains live in their own `ObservableObject` stores (`textToSpeech`,
/// `feedback`, `cleanupTuning`, ...), exposed under the same property names and
/// forwarded through this object's `objectWillChange`.
@MainActor
final class AppSettings: ObservableObject {
  typealias DefaultsKey = ApplicationPreferenceKey
  /// Keys, defaults and value domains shared with the iOS store.
  private typealias Shared = SharedApplicationPreferences

  @Published var appearance: Appearance {
    didSet { persistence.store(appearance.rawValue, key: .appearance) }
  }

  @Published var transcriptionMode: TranscriptionMode {
    didSet {
      persistence.store(transcriptionMode.rawValue, key: .transcriptionMode)
      enforceSpeedModeConstraints()
    }
  }

  @Published var liveTranscriptionModel: String {
    didSet {
      persistence.store(liveTranscriptionModel, key: .liveTranscriptionModel)
      // Session-scoped profile overrides must not rewrite the user's own memory.
      if !suppressesPersistence {
        liveTranscriptionSelection.remember(liveTranscriptionModel)
      }
      enforceSpeedModeConstraints()
    }
  }

  /// Per-placement memory of the user's live transcription model choices, so
  /// switching between local and remote never discards the other side's model.
  private(set) var liveTranscriptionSelection: LiveTranscriptionSelection {
    didSet { persistLiveTranscriptionSelection() }
  }

  @Published var batchTranscriptionModel: String {
    didSet {
      let normalized = ModelCatalog.normalizedBatchTranscriptionModel(batchTranscriptionModel)
      if normalized != batchTranscriptionModel {
        batchTranscriptionModel = normalized
        return
      }
      persistence.store(batchTranscriptionModel, key: .batchTranscriptionModel)
    }
  }

  @Published var localTranscriptionMode: LocalTranscriptionMode {
    didSet {
      if !DistributionChannel.current.supportsInProcessLocalStreaming, localTranscriptionMode == .streaming {
        localTranscriptionMode = .batch
        return
      }
      persistence.store(localTranscriptionMode.rawValue, key: .localTranscriptionMode)
    }
  }

  @Published var preferredLocaleIdentifier: String {
    didSet { persistence.store(preferredLocaleIdentifier, key: .preferredLocale) }
  }

  @Published var postProcessingEnabled: Bool {
    didSet {
      // Speed modes apply cleanup during recording; post-processing is disabled to avoid double-processing.
      if postProcessingEnabled && speedMode != .instant {
        postProcessingEnabled = false
        return
      }
      persistence.store(postProcessingEnabled, key: .postProcessingEnabled)
    }
  }

  /// Words the user wants every provider to bias towards.
  ///
  /// `transcriptionKeywords` is the canonical spelling — iOS has always stored
  /// them under that defaults key — and `assemblyAIKeyterms` is the older macOS
  /// name kept alive for the existing settings field, its `@Published`
  /// projection and the warm-up invalidation. The two are mirrored on every
  /// write, so there is one value with two surfaces rather than two lists that
  /// can disagree; the equality check makes the mirror terminate.
  @Published var assemblyAIKeyterms: String {
    didSet {
      persistence.store(assemblyAIKeyterms, key: .assemblyAIKeyterms)
      if transcriptionKeywords != assemblyAIKeyterms {
        transcriptionKeywords = assemblyAIKeyterms
      }
      persistence.store(assemblyAIKeyterms, key: .transcriptionKeywordsLastReconciled)
    }
  }

  @Published var transcriptionKeywords: String {
    didSet {
      persistence.store(transcriptionKeywords, key: .transcriptionKeywords)
      if assemblyAIKeyterms != transcriptionKeywords {
        assemblyAIKeyterms = transcriptionKeywords
      }
      persistence.store(transcriptionKeywords, key: .transcriptionKeywordsLastReconciled)
    }
  }

  /// Competing edits preserved when a deliberate clear wins reconciliation.
  /// They stay recoverable until the user restores or discards them in Settings.
  @Published private(set) var recoveredTranscriptionKeywords: [String] {
    didSet { persistence.store(recoveredTranscriptionKeywords, key: .recoveredTranscriptionKeywords) }
  }

  @Published var textOutputMethod: TextOutputMethod {
    didSet {
      let normalized = Self.normalizedTextOutputMethod(
        textOutputMethod,
        for: DistributionChannel.current
      )
      guard normalized == textOutputMethod else {
        textOutputMethod = normalized
        return
      }
      persistence.store(textOutputMethod.rawValue, key: .textOutputMethod)
    }
  }

  /// What happens when the user has switched away from the app where recording
  /// started by the time the transcript is ready. Defaults to the original app.
  @Published var appSwitchDelivery: AppSwitchDelivery {
    didSet { persistence.store(appSwitchDelivery.rawValue, key: .appSwitchDelivery) }
  }

  @Published var cancelRecordingOnEscape: Bool {
    didSet { persistence.store(cancelRecordingOnEscape, key: .cancelRecordingOnEscape) }
  }

  @Published var runAtLogin: Bool {
    didSet {
      persistence.store(runAtLogin, key: .runAtLogin)
      system.updateLoginItem(enabled: runAtLogin)
    }
  }

  @Published var recordingsDirectory: URL {
    didSet { persistence.store(recordingsDirectory.path, key: .recordingsDirectory) }
  }

  @Published var selectedHotKey: HotKey {
    didSet {
      do {
        let data = try JSONEncoder().encode(selectedHotKey)
        defaults.set(data, forKey: DefaultsKey.selectedHotKey.rawValue)
      } catch {
        log.error("Failed to encode selectedHotKey: \(error.localizedDescription)")
      }
    }
  }

  @Published private(set) var trackedAPIKeyIdentifiers: [String] {
    didSet { persistence.store(trackedAPIKeyIdentifiers, key: .trackedKeyIdentifiers) }
  }

  /// Hands-free dictation: the hotkey arms a listening session instead of
  /// starting capture, and speech starts/stops recording. Off by default, and
  /// inert below macOS 26 where on-device SpeechAnalyzer capture does not exist.
  @Published var handsFreeDictationEnabled: Bool {
    didSet { persistence.store(handsFreeDictationEnabled, key: .handsFreeDictationEnabled) }
  }

  // Performance Settings

  /// Pre-warms OpenRouter plus supported shared-session transcription endpoints
  /// while idle. No credential is sent and no provider session is opened.
  @Published var connectionPreWarmingEnabled: Bool {
    didSet { persistence.store(connectionPreWarmingEnabled, key: .connectionPreWarmingEnabled) }
  }

  /// Creates and prepares the audio recorder while the app is idle so the
  /// hotkey→capture path only has to start it (issue #663). Pre-warming never
  /// opens the microphone; capture still begins at session start. Costs one
  /// prepared encoder and one empty file while idle, so it is on by default.
  @Published var audioPreWarmingEnabled: Bool {
    didSet { persistence.store(audioPreWarmingEnabled, key: .audioPreWarmingEnabled) }
  }

  /// Opens the microphone the moment the dictation hotkey goes down, instead
  /// of once the hold is recognised, and closes it again if the press does
  /// not become a recording. Hides the hold threshold and a Bluetooth
  /// headset's switch to call mode inside the press. Accidental taps briefly
  /// show the microphone indicator.
  @Published var warmMicrophoneOnKeyPress: Bool {
    didSet { persistence.store(warmMicrophoneOnKeyPress, key: .warmMicrophoneOnKeyPress) }
  }

  // Speed Mode Settings (Live Polish)
  @Published var speedMode: SpeedMode {
    didSet {
      if !supports(speedMode: speedMode) {
        speedMode = .instant
        return
      }
      if speedMode != .instant {
        postProcessingEnabled = false
      }
      persistence.store(speedMode.rawValue, key: .speedMode)
    }
  }

  /// Experimental (issue #611): progressively stream partial transcripts into
  /// allowlisted apps via ranged accessibility replacement while dictating.
  /// Default OFF; non-allowlisted apps always keep the paste-at-end path.
  @Published var streamingInsertionEnabled: Bool {
    didSet { persistence.store(streamingInsertionEnabled, key: .streamingInsertionEnabled) }
  }

  // MARK: - Analytics

  /// Whether the user has opted into anonymous product analytics (PostHog).
  /// Defaults to `false` — events are never sent until the user explicitly enables this.
  @Published var analyticsEnabled: Bool {
    didSet { persistence.store(analyticsEnabled, key: .analyticsEnabled) }
  }

  @Published var recordingSoundProfile: RecordingSoundPlayer.SoundProfile {
    didSet { persistence.store(recordingSoundProfile.rawValue, key: .recordingSoundProfile) }
  }

  let domains: AppSettingsDomains
  private var domainChanges: AnyCancellable?

  var migrationDefaults: UserDefaults { persistence.defaults }
  private var defaults: UserDefaults { persistence.defaults }
  private let persistence: AppSettingsPersistence
  private let system: SystemDependencies
  private let log = SpeakLogger.logger(category: "AppSettings")

  init(defaults: UserDefaults = .standard, system: SystemDependencies = .live) {
    let persistence = AppSettingsPersistence(defaults: defaults)
    self.persistence = persistence
    self.system = system
    let loadedTranscriptionMode: TranscriptionMode = persistence.choice(.transcriptionMode, default: .liveNative)
    domains = AppSettingsDomains(
      persistence: persistence, transcriptionMode: loadedTranscriptionMode,
      setActivationPolicy: system.setActivationPolicy
    )
    appearance = persistence.choice(.appearance, default: .system)
    transcriptionMode = loadedTranscriptionMode
    // Remote choices relaunch as saved unless the shared catalogue retired
    // them, so a current entry such as Deepgram Flux is never reset.
    liveTranscriptionModel = Shared.liveTranscriptionModel.macOS.value(in: defaults)
    liveTranscriptionSelection = LiveTranscriptionSelection(defaults: defaults)
    batchTranscriptionModel = Shared.batchTranscriptionModel.macOS.value(in: defaults)
    localTranscriptionMode = DistributionChannel.current.supportsInProcessLocalStreaming
      ? persistence.choice(.localTranscriptionMode, default: .batch)
      : .batch
    preferredLocaleIdentifier = Shared.preferredLocale.macOS.value(in: defaults)
    postProcessingEnabled = Shared.postProcessingEnabled.macOS.value(in: defaults)
    let keywords = AppSettingsLaunchValues.reconcileStoredTranscriptionKeywords(in: defaults)
    recoveredTranscriptionKeywords = keywords.recovered
    assemblyAIKeyterms = keywords.active
    transcriptionKeywords = keywords.active
    textOutputMethod = Self.normalizedTextOutputMethod(
      persistence.choice(.textOutputMethod, default: .clipboardOnly), for: DistributionChannel.current
    )
    appSwitchDelivery = defaults.string(forKey: DefaultsKey.appSwitchDelivery.rawValue)
      .flatMap(AppSwitchDelivery.init(rawValue:)) ?? AppSwitchDelivery.defaultValue
    cancelRecordingOnEscape =
      persistence.flag(.cancelRecordingOnEscape, default: SpeechDefaults.cancelRecordingOnEscape)
    runAtLogin = persistence.flag(.runAtLogin, default: false)
    recordingsDirectory =
      AppSettingsLaunchValues.storedRecordingsDirectory(in: defaults, fileManager: system.fileManager)
    selectedHotKey = AppSettingsLaunchValues.storedHotKey(in: defaults)
    trackedAPIKeyIdentifiers = persistence.strings(.trackedKeyIdentifiers)
    handsFreeDictationEnabled = Shared.handsFreeDictationEnabled.macOS.value(in: defaults)
    connectionPreWarmingEnabled =
      persistence.flag(.connectionPreWarmingEnabled, default: SpeechDefaults.connectionPreWarmingEnabled)
    audioPreWarmingEnabled = persistence.flag(.audioPreWarmingEnabled, default: true)
    warmMicrophoneOnKeyPress = persistence.flag(.warmMicrophoneOnKeyPress, default: true)
    speedMode = persistence.choice(.speedMode, default: .instant)
    streamingInsertionEnabled = persistence.flag(.streamingInsertionEnabled, default: false)
    analyticsEnabled = persistence.flag(.analyticsEnabled, default: false)
    recordingSoundProfile = persistence.choice(.recordingSoundProfile, default: RecordingFeedbackDefaults.profile)
    finishLaunch()
  }
}

extension AppSettings {
  private func persistLiveTranscriptionSelection() {
    guard !suppressesPersistence else { return }
    liveTranscriptionSelection.persist(to: defaults)
  }

  func restoreTranscriptionKeywords(_ recovered: String) {
    guard recoveredTranscriptionKeywords.contains(recovered) else { return }
    transcriptionKeywords = TranscriptionKeywordPolicy.reconcile(
      canonical: transcriptionKeywords, legacy: recovered, lastReconciled: nil
    ).active
    discardRecoveredTranscriptionKeywords(recovered)
  }

  func discardRecoveredTranscriptionKeywords(_ recovered: String) {
    recoveredTranscriptionKeywords.removeAll { $0 == recovered }
  }

  func registerAPIKeyIdentifier(_ identifier: String) {
    reconcileAPIKeyIdentifiers(trackedAPIKeyIdentifiers + [identifier])
  }

  func removeAPIKeyIdentifier(_ identifier: String) {
    reconcileAPIKeyIdentifiers(trackedAPIKeyIdentifiers.filter { $0 != identifier })
  }

  func reconcileAPIKeyIdentifiers(_ identifiers: [String]) {
    let reconciled = Array(Set(identifiers)).sorted()
    guard trackedAPIKeyIdentifiers != reconciled else { return }
    trackedAPIKeyIdentifiers = reconciled
  }

  private func enforceSpeedModeConstraints() {
    if !supports(speedMode: speedMode) {
      speedMode = .instant
    }
    if speedMode != .instant {
      postProcessingEnabled = false
    }
  }

  /// When true, `store` skips writing to `UserDefaults` while the published
  /// in-memory values still update. Used by `SessionProfileApplier` so
  /// session-scoped dictation-profile overrides never touch persisted defaults.
  var suppressesPersistence: Bool {
    get { persistence.isSuppressed }
    set { persistence.isSuppressed = newValue }
  }

  func reloadAfterMigration() {
    let restored = AppSettings(defaults: defaults)
    suppressesPersistence = true
    defer { suppressesPersistence = false }
    reloadMigrationSelection(restored)
    reloadMigrationShellAndCapture(restored)
    domains.reload(from: restored.domains)
    recoveredTranscriptionKeywords = restored.recoveredTranscriptionKeywords
    trackedAPIKeyIdentifiers = restored.trackedAPIKeyIdentifiers
    liveTranscriptionSelection = restored.liveTranscriptionSelection
    // Restore dependent values after model and speed-mode observers have settled.
    postProcessingEnabled = restored.postProcessingEnabled
  }

  /// Applies launch-time side effects once every stored value is loaded.
  private func finishLaunch() {
    // Republish every domain store's changes so views observing `AppSettings`
    // refresh exactly as they did when those properties were published here.
    domainChanges = domains.willChange.sink { [weak self] _ in self?.objectWillChange.send() }
    AppSettingsLaunchValues.ensureDirectoryExists(recordingsDirectory, fileManager: system.fileManager)
    applyAppVisibility()
    system.updateLoginItem(enabled: runAtLogin)
    // `didSet` never fires during init, so seed and persist the per-placement
    // model memory explicitly. Existing installs upgrade with their current
    // model remembered for the placement it belongs to; the other placement
    // stays empty until the user chooses there.
    liveTranscriptionSelection.rememberIfMissing(liveTranscriptionModel)
    persistLiveTranscriptionSelection()
  }
}
