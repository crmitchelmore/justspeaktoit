import Foundation
import SpeakCore

/// Reads, validates and applies the raw settings configuration (issue #1546) for
/// the raw editor and the `get_configuration` / `set_configuration` automation
/// tools. Every schema key has one binding; a document is applied all or none.
@MainActor
final class AppSettingsConfiguration {
  typealias JSONValue = AnyCodable.JSONValue

  /// `UserDefaults` key for settings another platform owns: kept so an
  /// imported document exports again without loss, never applied here.
  static let foreignSettingsDefaultsKey = "rawConfiguration.foreignSettings"

  struct Binding {
    let read: @MainActor (AppSettings) -> JSONValue
    /// Nil for read-only fields, which the validator never lets through.
    let write: (@MainActor (AppSettings, JSONValue) -> Void)?
  }

  struct ApplyError: Error, Equatable {
    let issues: [SettingsIssue]
  }

  private let settings: AppSettings
  private let hasAPIKey: @MainActor (String) async -> Bool

  init(settings: AppSettings, hasAPIKey: @escaping @MainActor (String) async -> Bool) {
    self.settings = settings
    self.hasAPIKey = hasAPIKey
  }

  // MARK: Reading

  /// The current value of every bound setting.
  func currentValues() -> [String: JSONValue] {
    Self.bindings.mapValues { $0.read(settings) }
  }

  /// The full document: current values, preserved foreign keys and which API
  /// keys are stored. Never contains a secret.
  func document() async -> SettingsDocument {
    var values = foreignSettings()
    values.merge(currentValues()) { _, current in current }
    var apiKeys: [String: Bool] = [:]
    for identifier in settings.trackedAPIKeyIdentifiers.sorted() {
      apiKeys[identifier] = await hasAPIKey(identifier)
    }
    return SettingsDocument(platform: "macOS", settings: values, apiKeys: apiKeys)
  }

  /// A document holding every schema default; device-dependent fields (with no
  /// default) and read-only fields keep their current value.
  func defaultsDocument() -> SettingsDocument {
    var values = currentValues()
    for field in SettingsSchema.fields where !field.isReadOnly {
      if let value = field.defaultValue { values[field.key] = value }
    }
    return SettingsDocument(platform: "macOS", settings: values)
  }

  // MARK: Validating and applying

  func validationContext(ignoringReadOnly: Bool = false) -> SettingsValidationContext {
    SettingsValidationContext(
      currentValues: currentValues(),
      additionalModelIDs: [
        .localTranscription: [settings.localTranscriptionModel],
        .postProcessing: [settings.postProcessingModel],
        .livePolish: [settings.livePolishModel],
      ],
      ignoresReadOnlyChanges: ignoringReadOnly
    )
  }

  /// Validates a whole document, as the raw editor and file import do. A
  /// document exported on another Mac may differ in read-only fields, so those
  /// are kept with a warning instead of failing.
  func validate(document: SettingsDocument) -> SettingsValidationReport {
    var report = SettingsValidator.validate(document, context: validationContext(ignoringReadOnly: true))
    report.errors += hostIssues(report.changes)
    return report
  }

  /// Validates individual changes, as `set_configuration` does.
  func validate(changes: [String: JSONValue]) -> SettingsValidationReport {
    var report = SettingsValidator.validate(settings: changes, context: validationContext())
    report.errors += hostIssues(report.changes)
    return report
  }

  /// Applies a valid report's changes all or none: if any setting reads back
  /// differently, every setting is restored. Foreign keys are remembered.
  func apply(_ report: SettingsValidationReport, foreign: [String: JSONValue] = [:]) throws {
    guard report.isValid else { throw ApplyError(issues: report.errors) }
    let snapshot = currentValues()
    for key in Self.applyOrder(report.changes.keys) {
      guard let value = report.changes[key] else { continue }
      Self.bindings[key]?.write?(settings, value)
    }
    let after = currentValues()
    let mismatched = report.changes.keys.sorted().filter { after[$0] != report.changes[$0] }
    guard mismatched.isEmpty else {
      restore(snapshot)
      throw ApplyError(issues: mismatched.map {
        SettingsIssue(path: "settings.\($0)", message: "The app did not accept this value; nothing was changed.")
      })
    }
    if !foreign.isEmpty {
      var stored = foreignSettings()
      stored.merge(foreign) { _, new in new }
      storeForeignSettings(stored)
    }
  }

  /// `set_configuration`: validates every change and, unless `dryRun`, applies
  /// them all or none. Refused unless the user allowed automated writes; a dry
  /// run always works.
  func automationSet(
    _ changes: [String: JSONValue], dryRun: Bool, writesAllowed: Bool
  ) throws -> AutomationResult {
    guard dryRun || writesAllowed else { throw AutomationConfiguration.writesNotAllowed }
    let report = validate(changes: changes)
    try AutomationConfiguration.requireValid(report)
    if !dryRun {
      do {
        try apply(report)
      } catch let error as ApplyError {
        throw AutomationError(
          code: .invalidArgument,
          message: "Configuration not changed. " + error.issues.map(\.description).joined(separator: "; "))
      }
    }
    return try AutomationConfiguration.setResult(report, dryRun: dryRun)
  }

  /// The parts of a document's settings that belong to another platform.
  static func foreignValues(of document: SettingsDocument, report: SettingsValidationReport) -> [String: JSONValue] {
    document.settings.filter { report.ignoredKeys.contains($0.key) }
  }

  private func restore(_ snapshot: [String: JSONValue]) {
    for key in Self.applyOrder(snapshot.keys) {
      guard let value = snapshot[key], Self.bindings[key]?.read(settings) != value else { continue }
      Self.bindings[key]?.write?(settings, value)
    }
  }

  /// Checks the schema cannot express: a recordings folder must exist.
  private func hostIssues(_ changes: [String: JSONValue]) -> [SettingsIssue] {
    guard case .string(let path)? = changes["recordingsDirectory"] else { return [] }
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    guard path.hasPrefix("/"), exists, isDirectory.boolValue else {
      return [.init(path: "settings.recordingsDirectory", message: "Must be the absolute path of an existing folder.")]
    }
    return []
  }

  /// Models and modes first, then the Auto-Clean speed and cleanup switches
  /// that depend on them, so intermediate states stay coherent.
  private static func applyOrder<Keys: Sequence>(_ keys: Keys) -> [String] where Keys.Element == String {
    let late = ["speedMode", "postProcessingEnabled"]
    let sorted = keys.sorted()
    return sorted.filter { !late.contains($0) } + late.filter(sorted.contains)
  }

  private func foreignSettings() -> [String: JSONValue] {
    guard let data = settings.migrationDefaults.data(forKey: Self.foreignSettingsDefaultsKey),
          let decoded = try? JSONDecoder().decode(AnyCodable.self, from: data),
          case .object(let values) = decoded.storage
    else { return [:] }
    return values.filter { SettingsSchema.field(forKey: $0.key) == nil }
  }

  private func storeForeignSettings(_ values: [String: JSONValue]) {
    guard let data = try? JSONEncoder().encode(AnyCodable(.object(values))) else { return }
    settings.migrationDefaults.set(data, forKey: Self.foreignSettingsDefaultsKey)
  }
}

// MARK: - Bindings

extension AppSettingsConfiguration {
  /// One read/write binding per macOS schema key.
  static let bindings: [String: Binding] = {
    var table: [String: Binding] = [:]
    func bool(_ key: String, _ path: ReferenceWritableKeyPath<AppSettings, Bool>) {
      table[key] = Binding(read: { .bool($0[keyPath: path]) }, write: { settings, value in
        if case .bool(let bool) = value { settings[keyPath: path] = bool }
      })
    }
    func string(_ key: String, _ path: ReferenceWritableKeyPath<AppSettings, String>) {
      table[key] = Binding(read: { .string($0[keyPath: path]) }, write: { settings, value in
        if case .string(let string) = value { settings[keyPath: path] = string }
      })
    }
    func double(_ key: String, _ path: ReferenceWritableKeyPath<AppSettings, Double>) {
      table[key] = Binding(read: { .double($0[keyPath: path]) }, write: { settings, value in
        if let number = AppSettingsConfiguration.number(value) { settings[keyPath: path] = number }
      })
    }
    func float(_ key: String, _ path: ReferenceWritableKeyPath<AppSettings, Float>) {
      // Through the shortest decimal form, so 0.7 reads back as 0.7, not 0.699999988.
      table[key] = Binding(read: { .double(Double("\($0[keyPath: path])") ?? 0) }, write: { settings, value in
        if let number = AppSettingsConfiguration.number(value) { settings[keyPath: path] = Float(number) }
      })
    }
    func int(_ key: String, _ path: ReferenceWritableKeyPath<AppSettings, Int>) {
      table[key] = Binding(read: { .int($0[keyPath: path]) }, write: { settings, value in
        if case .int(let int) = value { settings[keyPath: path] = int }
      })
    }
    func strings(_ key: String, _ path: ReferenceWritableKeyPath<AppSettings, [String]>) {
      table[key] = Binding(read: { .array($0[keyPath: path].map(JSONValue.string)) }, write: { settings, value in
        guard case .array(let items) = value else { return }
        settings[keyPath: path] = items.compactMap { if case .string(let item) = $0 { item } else { nil } }
      })
    }
    func choice<Choice: RawRepresentable>(
      _ key: String, _ path: ReferenceWritableKeyPath<AppSettings, Choice>
    ) where Choice.RawValue == String {
      table[key] = Binding(read: { .string($0[keyPath: path].rawValue) }, write: { settings, value in
        if case .string(let raw) = value, let choice = Choice(rawValue: raw) { settings[keyPath: path] = choice }
      })
    }
    func readOnly(_ key: String, _ read: @escaping @MainActor (AppSettings) -> JSONValue) {
      table[key] = Binding(read: read, write: nil)
    }

    // General
    choice("appearance", \.appearance)
    choice("appVisibility", \.appVisibility)
    bool("showStatusBarIconInDockOnly", \.showStatusBarIconInDockOnly)
    bool("compactStatusBarIcon", \.compactStatusBarIcon)
    bool("runAtLogin", \.runAtLogin)
    choice("visualDensity", \.visualDensity)
    bool("showSidebarShortcutHints", \.showSidebarShortcutHints)
    table["recordingsDirectory"] = Binding(read: { .string($0.recordingsDirectory.path) }, write: { settings, value in
      if case .string(let path) = value { settings.recordingsDirectory = URL(fileURLWithPath: path, isDirectory: true) }
    })
    readOnly("analyticsEnabled") { .bool($0.analyticsEnabled) }

    // Transcription
    choice("transcriptionMode", \.transcriptionMode)
    string("liveTranscriptionModel", \.liveTranscriptionModel)
    string("batchTranscriptionModel", \.batchTranscriptionModel)
    choice("localTranscriptionMode", \.localTranscriptionMode)
    string("localTranscriptionModel", \.localTranscriptionModel)
    choice("rememberedLocalTranscriptionSource", \.rememberedLocalTranscriptionSource)
    choice("rememberedRemoteTranscriptionMode", \.rememberedRemoteTranscriptionMode)
    string("preferredLocaleIdentifier", \.preferredLocaleIdentifier)
    table["preferredAudioInputUID"] = Binding(
      read: { $0.preferredAudioInputUID.map(JSONValue.string) ?? .null },
      write: { settings, value in
        switch value {
        case .string(let uid): settings.preferredAudioInputUID = uid
        case .null: settings.preferredAudioInputUID = nil
        default: break
        }
      })
    string("transcriptionKeywords", \.transcriptionKeywords)
    strings("assemblyAIIgnoredPronunciationTerms", \.assemblyAIIgnoredPronunciationTerms)
    bool("modulateSpeakerDiarizationEnabled", \.modulateSpeakerDiarizationEnabled)
    bool("modulateEmotionSignalEnabled", \.modulateEmotionSignalEnabled)
    bool("modulateAccentSignalEnabled", \.modulateAccentSignalEnabled)
    bool("modulatePIIPhiTaggingEnabled", \.modulatePIIPhiTaggingEnabled)
    double("postRecordingTailDuration", \.postRecordingTailDuration)
    double("liveStopGracePeriod", \.liveStopGracePeriod)
    bool("connectionPreWarmingEnabled", \.connectionPreWarmingEnabled)
    bool("audioPreWarmingEnabled", \.audioPreWarmingEnabled)
    bool("warmMicrophoneOnKeyPress", \.warmMicrophoneOnKeyPress)

    // Speed and cleanup
    choice("speedMode", \.speedMode)
    bool("postProcessingEnabled", \.postProcessingEnabled)
    string("postProcessingModel", \.postProcessingModel)
    bool("cleanupModelDiscoveryEnabled", \.cleanupModelDiscoveryEnabled)
    double("postProcessingTemperature", \.postProcessingTemperature)
    string("postProcessingOutputLanguage", \.postProcessingOutputLanguage)
    bool("postProcessingIncludeLexiconDirectives", \.postProcessingIncludeLexiconDirectives)
    bool("postProcessingIncludeContextTags", \.postProcessingIncludeContextTags)
    bool("postProcessingStreamingEnabled", \.postProcessingStreamingEnabled)
    string("livePolishModel", \.livePolishModel)
    int("livePolishDebounceMs", \.livePolishDebounceMs)
    int("livePolishMinDeltaChars", \.livePolishMinDeltaChars)
    int("livePolishTailWindowChars", \.livePolishTailWindowChars)
    bool("skipPostProcessingWithLivePolish", \.skipPostProcessingWithLivePolish)

    // Shortcuts and dictation
    readOnly("selectedHotKey") { settings in
      guard let data = try? JSONEncoder().encode(settings.selectedHotKey),
            let decoded = try? JSONDecoder().decode(AnyCodable.self, from: data)
      else { return .null }
      return decoded.storage
    }
    choice("hotKeyActivationStyle", \.hotKeyActivationStyle)
    double("holdThreshold", \.holdThreshold)
    double("doubleTapWindow", \.doubleTapWindow)
    bool("handsFreeDictationEnabled", \.handsFreeDictationEnabled)
    bool("silenceDetectionEnabled", \.silenceDetectionEnabled)
    float("silenceThreshold", \.silenceThreshold)
    double("silenceDuration", \.silenceDuration)
    double("historyFlushInterval", \.historyFlushInterval)
    bool("voiceCommandsEnabled", \.voiceCommandsEnabled)
    string("clipboardInsertionTriggers", \.clipboardInsertionTriggers)
    bool("autoCorrectionsEnabled", \.autoCorrectionsEnabled)
    int("autoCorrectionsPromotionThreshold", \.autoCorrectionsPromotionThreshold)
    bool("keepAudioOnCancel", \.keepAudioOnCancel)
    bool("cancelRecordingOnEscape", \.cancelRecordingOnEscape)

    // Output and HUD
    choice("textOutputMethod", \.textOutputMethod)
    choice("accessibilityInsertionMode", \.accessibilityInsertionMode)
    bool("restoreClipboardAfterPaste", \.restoreClipboardAfterPaste)
    choice("appSwitchDelivery", \.appSwitchDelivery)
    bool("streamingInsertionEnabled", \.streamingInsertionEnabled)
    bool("showHUDDuringSessions", \.showHUDDuringSessions)
    bool("showLiveTranscriptInHUD", \.showLiveTranscriptInHUD)
    bool("showCompactHUD", \.showCompactHUD)
    bool("shortenErrorDisplay", \.shortenErrorDisplay)
    choice("hudSizePreference", \.hudSizePreference)
    bool("recordingSoundsEnabled", \.recordingSoundsEnabled)
    choice("recordingSoundProfile", \.recordingSoundProfile)
    float("recordingSoundVolume", \.recordingSoundVolume)

    // Voice output
    string("defaultTTSVoice", \.defaultTTSVoice)
    string("ttsLanguageIdentifier", \.ttsLanguageIdentifier)
    choice("mistralTTSModel", \.mistralTTSModel)
    choice("sonioxTTSRegion", \.sonioxTTSRegion)
    double("ttsSpeed", \.ttsSpeed)
    double("ttsPitch", \.ttsPitch)
    choice("ttsQuality", \.ttsQuality)
    choice("ttsOutputFormat", \.ttsOutputFormat)
    bool("ttsAutoPlay", \.ttsAutoPlay)
    bool("ttsSaveToDirectory", \.ttsSaveToDirectory)
    bool("ttsUseSSML", \.ttsUseSSML)
    strings("ttsFavoriteVoices", \.ttsFavoriteVoices)
    table["ttsPronunciationDictionary"] = Binding(
      read: { .object($0.ttsPronunciationDictionary.mapValues(JSONValue.string)) },
      write: { settings, value in
        guard case .object(let items) = value else { return }
        settings.ttsPronunciationDictionary = items.compactMapValues {
          if case .string(let item) = $0 { item } else { nil }
        }
      })

    // Integrations
    bool("paidAccessRoutingEnabled", \.paidAccessRoutingEnabled)
    bool("simpleModelChoices", \.simpleModelChoices)
    bool("enableSendToMac", \.enableSendToMac)
    bool("pasteRemoteTranscriptsAtCursor", \.pasteRemoteTranscriptsAtCursor)
    readOnly("enableAutomationServer") { .bool($0.enableAutomationServer) }
    readOnly("allowAutomationConfigurationChanges") { .bool($0.allowAutomationConfigurationChanges) }
    return table
  }()

  private static func number(_ value: JSONValue) -> Double? {
    switch value {
    case .int(let int): Double(int)
    case .double(let double): double
    default: nil
    }
  }
}
