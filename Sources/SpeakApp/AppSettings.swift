import Foundation

/// Centralised configuration model backed by `UserDefaults` and published to SwiftUI.
@MainActor
final class AppSettings: ObservableObject {
  enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
  }

  enum TranscriptionMode: String, CaseIterable, Identifiable {
    case liveNative
    case batchRemote

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .liveNative:
        return "Live (On-device)"
      case .batchRemote:
        return "Batch (Remote)"
      }
    }
  }

  enum TextOutputMethod: String, CaseIterable, Identifiable {
    case smart
    case accessibilityOnly
    case clipboardOnly

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .smart:
        return "Smart (Auto)"
      case .accessibilityOnly:
        return "Accessibility"
      case .clipboardOnly:
        return "Clipboard"
      }
    }
  }

  enum HotKeyActivationStyle: String, CaseIterable, Identifiable {
    case holdToRecord
    case doubleTapToggle
    case holdAndDoubleTap

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .holdToRecord:
        return "Press & Hold"
      case .doubleTapToggle:
        return "Double Tap"
      case .holdAndDoubleTap:
        return "Hold & Double Tap"
      }
    }

    var allowsHold: Bool {
      switch self {
      case .holdToRecord, .holdAndDoubleTap:
        return true
      case .doubleTapToggle:
        return false
      }
    }

    var allowsDoubleTap: Bool {
      switch self {
      case .doubleTapToggle, .holdAndDoubleTap:
        return true
      case .holdToRecord:
        return false
      }
    }
  }

  enum HUDSizePreference: String, CaseIterable, Identifiable {
    case compact
    case expanded
    case autoExpand

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .compact:
        return "Compact"
      case .expanded:
        return "Always Expanded"
      case .autoExpand:
        return "Auto-Expand"
      }
    }
  }

  enum DefaultsKey: String {
    case appearance
    case transcriptionMode
    case liveTranscriptionModel
    case batchTranscriptionModel
    case postProcessingEnabled
    case postProcessingModel
    case postProcessingTemperature
    case postProcessingSystemPrompt
    case postProcessingOutputLanguage
    case postProcessingIncludeLexiconDirectives
    case postProcessingIncludeContextTags
    case postProcessingIncludeFinalInstruction
    case textOutputMethod
    case restoreClipboard
    case showHUD
    case showStatusBarOnly
    case runAtLogin
    case recordingsDirectory
    case hotKeyActivation
    case holdThreshold
    case doubleTapWindow
    case trackedKeyIdentifiers
    case preferredLocale
    case postRecordingTailDuration
    case preferredAudioInputUID
    case defaultTTSVoice
    case ttsSpeed
    case ttsPitch
    case ttsQuality
    case ttsOutputFormat
    case ttsAutoPlay
    case ttsSaveToDirectory
    case ttsUseSSML
    case ttsFavoriteVoices
    case ttsPronunciationDictionary
    case historyFlushInterval
    case silenceDetectionEnabled
    case silenceThreshold
    case silenceDuration
    case connectionPreWarmingEnabled
    case postProcessingStreamingEnabled
    case hudSizePreference
    case showLiveTranscriptInHUD
  }

  private static let defaultBatchTranscriptionModel = "google/gemini-2.0-flash-001"
  private static let legacyWhisperModelIDs: Set<String> = [
    "openrouter/whisper-large-v3",
    "openrouter/whisper-medium",
    "openrouter/whisper-small",
  ]
  private static let defaultPostProcessingModel = "openai/gpt-4o-mini"
  private static let legacyPostProcessingModelMapping: [String: String] = [
    "openrouter/gpt-4o-mini": defaultPostProcessingModel,
    "openrouter/gpt-4o": "openai/gpt-4o",
  ]

  @Published var appearance: Appearance {
    didSet { store(appearance.rawValue, key: .appearance) }
  }

  @Published var transcriptionMode: TranscriptionMode {
    didSet { store(transcriptionMode.rawValue, key: .transcriptionMode) }
  }

  @Published var liveTranscriptionModel: String {
    didSet { store(liveTranscriptionModel, key: .liveTranscriptionModel) }
  }

  @Published var batchTranscriptionModel: String {
    didSet {
      let normalized = Self.normalizedBatchModel(batchTranscriptionModel)
      if normalized != batchTranscriptionModel {
        batchTranscriptionModel = normalized
        return
      }
      store(batchTranscriptionModel, key: .batchTranscriptionModel)
    }
  }

  @Published var preferredLocaleIdentifier: String {
    didSet { store(preferredLocaleIdentifier, key: .preferredLocale) }
  }

  @Published var preferredAudioInputUID: String? {
    didSet {
      let key = DefaultsKey.preferredAudioInputUID.rawValue
      if let value = preferredAudioInputUID, !value.isEmpty {
        defaults.set(value, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
    }
  }

  @Published var postProcessingEnabled: Bool {
    didSet { store(postProcessingEnabled, key: .postProcessingEnabled) }
  }

  @Published var postProcessingModel: String {
    didSet {
      let normalized = Self.normalizedPostProcessingModel(postProcessingModel)
      if normalized != postProcessingModel {
        postProcessingModel = normalized
        return
      }
      store(postProcessingModel, key: .postProcessingModel)
    }
  }

  @Published var postProcessingTemperature: Double {
    didSet { store(postProcessingTemperature, key: .postProcessingTemperature) }
  }

  @Published var postProcessingSystemPrompt: String {
    didSet { store(postProcessingSystemPrompt, key: .postProcessingSystemPrompt) }
  }

  @Published var postProcessingOutputLanguage: String {
    didSet { store(postProcessingOutputLanguage, key: .postProcessingOutputLanguage) }
  }

  @Published var postProcessingIncludeLexiconDirectives: Bool {
    didSet { store(postProcessingIncludeLexiconDirectives, key: .postProcessingIncludeLexiconDirectives) }
  }

  @Published var postProcessingIncludeContextTags: Bool {
    didSet { store(postProcessingIncludeContextTags, key: .postProcessingIncludeContextTags) }
  }

  @Published var postProcessingIncludeFinalInstruction: Bool {
    didSet { store(postProcessingIncludeFinalInstruction, key: .postProcessingIncludeFinalInstruction) }
  }

  @Published var textOutputMethod: TextOutputMethod {
    didSet { store(textOutputMethod.rawValue, key: .textOutputMethod) }
  }

  @Published var restoreClipboardAfterPaste: Bool {
    didSet { store(restoreClipboardAfterPaste, key: .restoreClipboard) }
  }

  @Published var showHUDDuringSessions: Bool {
    didSet { store(showHUDDuringSessions, key: .showHUD) }
  }

  @Published var showLiveTranscriptInHUD: Bool {
    didSet { store(showLiveTranscriptInHUD, key: .showLiveTranscriptInHUD) }
  }

  @Published var showStatusBarOnly: Bool {
    didSet { store(showStatusBarOnly, key: .showStatusBarOnly) }
  }

  @Published var runAtLogin: Bool {
    didSet { store(runAtLogin, key: .runAtLogin) }
  }

  @Published var recordingsDirectory: URL {
    didSet { store(recordingsDirectory.path, key: .recordingsDirectory) }
  }

  @Published var hotKeyActivationStyle: HotKeyActivationStyle {
    didSet { store(hotKeyActivationStyle.rawValue, key: .hotKeyActivation) }
  }

  @Published var holdThreshold: TimeInterval {
    didSet { store(holdThreshold, key: .holdThreshold) }
  }

  @Published var doubleTapWindow: TimeInterval {
    didSet { store(doubleTapWindow, key: .doubleTapWindow) }
  }

  @Published var postRecordingTailDuration: TimeInterval {
    didSet { store(postRecordingTailDuration, key: .postRecordingTailDuration) }
  }

  @Published private(set) var trackedAPIKeyIdentifiers: [String] {
    didSet { store(trackedAPIKeyIdentifiers, key: .trackedKeyIdentifiers) }
  }

  // TTS Settings
  @Published var defaultTTSVoice: String {
    didSet { store(defaultTTSVoice, key: .defaultTTSVoice) }
  }

  @Published var ttsSpeed: Double {
    didSet { store(ttsSpeed, key: .ttsSpeed) }
  }

  @Published var ttsPitch: Double {
    didSet { store(ttsPitch, key: .ttsPitch) }
  }

  @Published var ttsQuality: TTSQuality {
    didSet { store(ttsQuality.rawValue, key: .ttsQuality) }
  }

  @Published var ttsOutputFormat: AudioFormat {
    didSet { store(ttsOutputFormat.rawValue, key: .ttsOutputFormat) }
  }

  @Published var ttsAutoPlay: Bool {
    didSet { store(ttsAutoPlay, key: .ttsAutoPlay) }
  }

  @Published var ttsSaveToDirectory: Bool {
    didSet { store(ttsSaveToDirectory, key: .ttsSaveToDirectory) }
  }

  @Published var ttsUseSSML: Bool {
    didSet { store(ttsUseSSML, key: .ttsUseSSML) }
  }

  /// Favorite TTS voice IDs for quick access
  @Published var ttsFavoriteVoices: [String] {
    didSet { store(ttsFavoriteVoices, key: .ttsFavoriteVoices) }
  }

  /// TTS pronunciation dictionary - maps words to phonetic spellings
  @Published var ttsPronunciationDictionary: [String: String] {
    didSet {
      if let data = try? JSONEncoder().encode(ttsPronunciationDictionary) {
        defaults.set(data, forKey: DefaultsKey.ttsPronunciationDictionary.rawValue)
      }
    }
  }

  // History Settings
  @Published var historyFlushInterval: TimeInterval {
    didSet { store(historyFlushInterval, key: .historyFlushInterval) }
  }

  // Silence Detection Settings
  @Published var silenceDetectionEnabled: Bool {
    didSet { store(silenceDetectionEnabled, key: .silenceDetectionEnabled) }
  }

  /// Silence threshold (0.0 to 1.0) - audio levels below this are considered silence
  @Published var silenceThreshold: Float {
    didSet { store(Double(silenceThreshold), key: .silenceThreshold) }
  }

  /// Duration of continuous silence (in seconds) before auto-stopping
  @Published var silenceDuration: TimeInterval {
    didSet { store(silenceDuration, key: .silenceDuration) }
  }

  // Performance Settings
  @Published var connectionPreWarmingEnabled: Bool {
    didSet { store(connectionPreWarmingEnabled, key: .connectionPreWarmingEnabled) }
  }

  @Published var postProcessingStreamingEnabled: Bool {
    didSet { store(postProcessingStreamingEnabled, key: .postProcessingStreamingEnabled) }
  }

  // HUD Settings
  @Published var hudSizePreference: HUDSizePreference {
    didSet { store(hudSizePreference.rawValue, key: .hudSizePreference) }
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults

    appearance =
      Appearance(
        rawValue: defaults.string(forKey: DefaultsKey.appearance.rawValue)
          ?? Appearance.system.rawValue) ?? .system
    transcriptionMode =
      TranscriptionMode(
        rawValue: defaults.string(forKey: DefaultsKey.transcriptionMode.rawValue)
          ?? TranscriptionMode.liveNative.rawValue) ?? .liveNative
    liveTranscriptionModel =
      defaults.string(forKey: DefaultsKey.liveTranscriptionModel.rawValue)
      ?? "apple/local/SFSpeechRecognizer"
    batchTranscriptionModel =
      Self.normalizedBatchModel(
        defaults.string(forKey: DefaultsKey.batchTranscriptionModel.rawValue))
    preferredLocaleIdentifier =
      defaults.string(forKey: DefaultsKey.preferredLocale.rawValue) ?? Locale.current.identifier
    preferredAudioInputUID = defaults.string(forKey: DefaultsKey.preferredAudioInputUID.rawValue)
    postProcessingEnabled =
      defaults.object(forKey: DefaultsKey.postProcessingEnabled.rawValue) as? Bool ?? true
    postProcessingModel = Self.normalizedPostProcessingModel(
      defaults.string(forKey: DefaultsKey.postProcessingModel.rawValue)
    )
    postProcessingTemperature =
      defaults.object(forKey: DefaultsKey.postProcessingTemperature.rawValue) as? Double ?? 0.2
    postProcessingSystemPrompt =
      defaults.string(forKey: DefaultsKey.postProcessingSystemPrompt.rawValue)
      ?? "You are a transcription assistant. Clean up the text, fix punctuation, and respect speaker turns."
    postProcessingOutputLanguage =
      defaults.string(forKey: DefaultsKey.postProcessingOutputLanguage.rawValue) ?? "English"
    postProcessingIncludeLexiconDirectives =
      defaults.object(forKey: DefaultsKey.postProcessingIncludeLexiconDirectives.rawValue) as? Bool ?? true
    postProcessingIncludeContextTags =
      defaults.object(forKey: DefaultsKey.postProcessingIncludeContextTags.rawValue) as? Bool ?? true
    postProcessingIncludeFinalInstruction =
      defaults.object(forKey: DefaultsKey.postProcessingIncludeFinalInstruction.rawValue) as? Bool ?? true
    textOutputMethod =
      TextOutputMethod(
        rawValue: defaults.string(forKey: DefaultsKey.textOutputMethod.rawValue)
          ?? TextOutputMethod.smart.rawValue) ?? .smart
    restoreClipboardAfterPaste =
      defaults.object(forKey: DefaultsKey.restoreClipboard.rawValue) as? Bool ?? true
    showHUDDuringSessions = defaults.object(forKey: DefaultsKey.showHUD.rawValue) as? Bool ?? true
    showLiveTranscriptInHUD =
      defaults.object(forKey: DefaultsKey.showLiveTranscriptInHUD.rawValue) as? Bool ?? true
    showStatusBarOnly =
      defaults.object(forKey: DefaultsKey.showStatusBarOnly.rawValue) as? Bool ?? false
    runAtLogin = defaults.object(forKey: DefaultsKey.runAtLogin.rawValue) as? Bool ?? false

    let defaultDirectory = Self.defaultRecordingsDirectory()
    if let storedPath = defaults.string(forKey: DefaultsKey.recordingsDirectory.rawValue),
      !storedPath.isEmpty
    {
      recordingsDirectory = URL(fileURLWithPath: storedPath, isDirectory: true)
    } else {
      recordingsDirectory = defaultDirectory
    }

    hotKeyActivationStyle =
      HotKeyActivationStyle(
        rawValue: defaults.string(forKey: DefaultsKey.hotKeyActivation.rawValue)
          ?? HotKeyActivationStyle.holdToRecord.rawValue) ?? .holdToRecord
    holdThreshold = defaults.object(forKey: DefaultsKey.holdThreshold.rawValue) as? Double ?? 0.35
    doubleTapWindow =
      defaults.object(forKey: DefaultsKey.doubleTapWindow.rawValue) as? Double ?? 0.4
    postRecordingTailDuration =
      defaults.object(forKey: DefaultsKey.postRecordingTailDuration.rawValue) as? Double ?? 0.5
    trackedAPIKeyIdentifiers =
      defaults.array(forKey: DefaultsKey.trackedKeyIdentifiers.rawValue) as? [String] ?? []

    // TTS Settings
    defaultTTSVoice =
      defaults.string(forKey: DefaultsKey.defaultTTSVoice.rawValue) ?? "openai/alloy"
    ttsSpeed = defaults.object(forKey: DefaultsKey.ttsSpeed.rawValue) as? Double ?? 1.0
    ttsPitch = defaults.object(forKey: DefaultsKey.ttsPitch.rawValue) as? Double ?? 0.0
    ttsQuality =
      TTSQuality(rawValue: defaults.string(forKey: DefaultsKey.ttsQuality.rawValue) ?? "") ?? .high
    ttsOutputFormat =
      AudioFormat(rawValue: defaults.string(forKey: DefaultsKey.ttsOutputFormat.rawValue) ?? "")
      ?? .mp3
    ttsAutoPlay = defaults.object(forKey: DefaultsKey.ttsAutoPlay.rawValue) as? Bool ?? true
    ttsSaveToDirectory =
      defaults.object(forKey: DefaultsKey.ttsSaveToDirectory.rawValue) as? Bool ?? false
    ttsUseSSML = defaults.object(forKey: DefaultsKey.ttsUseSSML.rawValue) as? Bool ?? false
    ttsFavoriteVoices =
      defaults.array(forKey: DefaultsKey.ttsFavoriteVoices.rawValue) as? [String] ?? []
    if let pronData = defaults.data(forKey: DefaultsKey.ttsPronunciationDictionary.rawValue),
      let dict = try? JSONDecoder().decode([String: String].self, from: pronData)
    {
      ttsPronunciationDictionary = dict
    } else {
      ttsPronunciationDictionary = [:]
    }
    connectionPreWarmingEnabled =
      defaults.object(forKey: DefaultsKey.connectionPreWarmingEnabled.rawValue) as? Bool ?? true
    postProcessingStreamingEnabled =
      defaults.object(forKey: DefaultsKey.postProcessingStreamingEnabled.rawValue) as? Bool ?? true

    // HUD Settings
    hudSizePreference =
      HUDSizePreference(
        rawValue: defaults.string(forKey: DefaultsKey.hudSizePreference.rawValue)
          ?? HUDSizePreference.autoExpand.rawValue) ?? .autoExpand

    // History Settings
    historyFlushInterval =
      defaults.object(forKey: DefaultsKey.historyFlushInterval.rawValue) as? Double ?? 5.0

    // Silence Detection Settings
    silenceDetectionEnabled =
      defaults.object(forKey: DefaultsKey.silenceDetectionEnabled.rawValue) as? Bool ?? false
    silenceThreshold =
      Float(defaults.object(forKey: DefaultsKey.silenceThreshold.rawValue) as? Double ?? 0.05)
    silenceDuration =
      defaults.object(forKey: DefaultsKey.silenceDuration.rawValue) as? Double ?? 2.0

    ensureRecordingsDirectoryExists()
  }

  func registerAPIKeyIdentifier(_ identifier: String) {
    if !trackedAPIKeyIdentifiers.contains(identifier) {
      trackedAPIKeyIdentifiers.append(identifier)
    }
  }

  func removeAPIKeyIdentifier(_ identifier: String) {
    trackedAPIKeyIdentifiers.removeAll { $0 == identifier }
  }

  private func store<T>(_ value: T, key: DefaultsKey) {
    switch value {
    case let boolValue as Bool:
      defaults.set(boolValue, forKey: key.rawValue)
    case let stringValue as String:
      defaults.set(stringValue, forKey: key.rawValue)
    case let doubleValue as Double:
      defaults.set(doubleValue, forKey: key.rawValue)
    case let arrayValue as [String]:
      defaults.set(arrayValue, forKey: key.rawValue)
    default:
      defaults.set(value, forKey: key.rawValue)
    }
  }

  private static func normalizedBatchModel(_ identifier: String?) -> String {
    let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return defaultBatchTranscriptionModel }
    if legacyWhisperModelIDs.contains(trimmed) { return defaultBatchTranscriptionModel }
    return trimmed
  }

  private static func normalizedPostProcessingModel(_ identifier: String?) -> String {
    let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return defaultPostProcessingModel }
    if let mapped = legacyPostProcessingModelMapping[trimmed] {
      return mapped
    }
    return trimmed
  }

  private func ensureRecordingsDirectoryExists() {
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: recordingsDirectory.path) {
      try? fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
    }
  }

  private static func defaultRecordingsDirectory() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
    let appFolder = base.appendingPathComponent("SpeakApp", isDirectory: true)
    let recordings = appFolder.appendingPathComponent("Recordings", isDirectory: true)
    if !FileManager.default.fileExists(atPath: recordings.path) {
      try? FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    }
    return recordings
  }
}
