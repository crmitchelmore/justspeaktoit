import Foundation
import SpeakCore

/// How cleanup runs once a transcript exists: the cleanup model, completed
/// post-processing options and the Live Polish tuning used while dictating.
@MainActor
final class CleanupTuningPreferences: ObservableObject {
  private let persistence: AppSettingsPersistence

  @Published var postProcessingModel: String {
    didSet {
      let normalized = ModelCatalog.normalizedPostProcessingModel(postProcessingModel)
      if normalized != postProcessingModel {
        postProcessingModel = normalized
        return
      }
      persistence.store(postProcessingModel, key: .postProcessingModel)
    }
  }

  /// Device-local metadata discovery; intentionally outside automatic settings transfer.
  @Published var cleanupModelDiscoveryEnabled: Bool {
    didSet {
      persistence.defaults.set(
        cleanupModelDiscoveryEnabled, forKey: SharedApplicationPreferences.cleanupModelDiscoveryEnabled.macOS.key
      )
    }
  }

  @Published var postProcessingTemperature: Double {
    didSet { persistence.store(postProcessingTemperature, key: .postProcessingTemperature) }
  }

  @Published var postProcessingOutputLanguage: String {
    didSet { persistence.store(postProcessingOutputLanguage, key: .postProcessingOutputLanguage) }
  }

  @Published var postProcessingIncludeLexiconDirectives: Bool {
    didSet {
      persistence.store(postProcessingIncludeLexiconDirectives, key: .postProcessingIncludeLexiconDirectives)
    }
  }

  @Published var postProcessingIncludeContextTags: Bool {
    didSet { persistence.store(postProcessingIncludeContextTags, key: .postProcessingIncludeContextTags) }
  }

  @Published var postProcessingStreamingEnabled: Bool {
    didSet { persistence.store(postProcessingStreamingEnabled, key: .postProcessingStreamingEnabled) }
  }

  @Published var livePolishModel: String {
    didSet { persistence.store(livePolishModel, key: .livePolishModel) }
  }

  @Published var livePolishDebounceMs: Int {
    didSet { persistence.store(livePolishDebounceMs, key: .livePolishDebounceMs) }
  }

  @Published var livePolishMinDeltaChars: Int {
    didSet { persistence.store(livePolishMinDeltaChars, key: .livePolishMinDeltaChars) }
  }

  @Published var livePolishTailWindowChars: Int {
    didSet { persistence.store(livePolishTailWindowChars, key: .livePolishTailWindowChars) }
  }

  @Published var skipPostProcessingWithLivePolish: Bool {
    didSet { persistence.store(skipPostProcessingWithLivePolish, key: .skipPostProcessingWithLivePolish) }
  }

  init(persistence: AppSettingsPersistence) {
    self.persistence = persistence
    let defaults = persistence.defaults
    postProcessingModel = SharedApplicationPreferences.postProcessingModel.macOS.value(in: defaults)
    cleanupModelDiscoveryEnabled = SharedApplicationPreferences.cleanupModelDiscoveryEnabled.macOS.value(in: defaults)
    postProcessingTemperature = persistence.number(.postProcessingTemperature, default: SpeechDefaults.temperature)
    postProcessingOutputLanguage =
      defaults.string(forKey: ApplicationPreferenceKey.postProcessingOutputLanguage.rawValue)
      ?? SpeechDefaults.outputLanguage
    postProcessingIncludeLexiconDirectives = persistence.flag(.postProcessingIncludeLexiconDirectives, default: true)
    postProcessingIncludeContextTags = persistence.flag(.postProcessingIncludeContextTags, default: true)
    postProcessingStreamingEnabled =
      persistence.flag(.postProcessingStreamingEnabled, default: SpeechDefaults.postProcessingStreamingEnabled)
    livePolishModel = defaults.string(forKey: ApplicationPreferenceKey.livePolishModel.rawValue) ?? ""
    livePolishDebounceMs = persistence.integer(.livePolishDebounceMs, default: LivePolishPolicy.debounceMilliseconds)
    livePolishMinDeltaChars =
      persistence.integer(.livePolishMinDeltaChars, default: LivePolishPolicy.minimumDeltaCharacters)
    livePolishTailWindowChars =
      persistence.integer(.livePolishTailWindowChars, default: LivePolishPolicy.tailWindowCharacters)
    skipPostProcessingWithLivePolish =
      persistence.flag(.skipPostProcessingWithLivePolish, default: LivePolishPolicy.skipPostProcessing)
  }

  func reload(from restored: CleanupTuningPreferences) {
    postProcessingModel = restored.postProcessingModel
    cleanupModelDiscoveryEnabled = restored.cleanupModelDiscoveryEnabled
    postProcessingTemperature = restored.postProcessingTemperature
    postProcessingOutputLanguage = restored.postProcessingOutputLanguage
    postProcessingIncludeLexiconDirectives = restored.postProcessingIncludeLexiconDirectives
    postProcessingIncludeContextTags = restored.postProcessingIncludeContextTags
    postProcessingStreamingEnabled = restored.postProcessingStreamingEnabled
    livePolishModel = restored.livePolishModel
    livePolishDebounceMs = restored.livePolishDebounceMs
    livePolishMinDeltaChars = restored.livePolishMinDeltaChars
    livePolishTailWindowChars = restored.livePolishTailWindowChars
    skipPostProcessingWithLivePolish = restored.skipPostProcessingWithLivePolish
  }
}

extension AppSettings {
  var postProcessingModel: String {
    get { cleanupTuning.postProcessingModel }
    set { cleanupTuning.postProcessingModel = newValue }
  }

  var cleanupModelDiscoveryEnabled: Bool {
    get { cleanupTuning.cleanupModelDiscoveryEnabled }
    set { cleanupTuning.cleanupModelDiscoveryEnabled = newValue }
  }

  var postProcessingTemperature: Double {
    get { cleanupTuning.postProcessingTemperature }
    set { cleanupTuning.postProcessingTemperature = newValue }
  }

  var postProcessingOutputLanguage: String {
    get { cleanupTuning.postProcessingOutputLanguage }
    set { cleanupTuning.postProcessingOutputLanguage = newValue }
  }

  var postProcessingIncludeLexiconDirectives: Bool {
    get { cleanupTuning.postProcessingIncludeLexiconDirectives }
    set { cleanupTuning.postProcessingIncludeLexiconDirectives = newValue }
  }

  var postProcessingIncludeContextTags: Bool {
    get { cleanupTuning.postProcessingIncludeContextTags }
    set { cleanupTuning.postProcessingIncludeContextTags = newValue }
  }

  var postProcessingStreamingEnabled: Bool {
    get { cleanupTuning.postProcessingStreamingEnabled }
    set { cleanupTuning.postProcessingStreamingEnabled = newValue }
  }

  var livePolishModel: String {
    get { cleanupTuning.livePolishModel }
    set { cleanupTuning.livePolishModel = newValue }
  }

  var livePolishDebounceMs: Int {
    get { cleanupTuning.livePolishDebounceMs }
    set { cleanupTuning.livePolishDebounceMs = newValue }
  }

  var livePolishMinDeltaChars: Int {
    get { cleanupTuning.livePolishMinDeltaChars }
    set { cleanupTuning.livePolishMinDeltaChars = newValue }
  }

  var livePolishTailWindowChars: Int {
    get { cleanupTuning.livePolishTailWindowChars }
    set { cleanupTuning.livePolishTailWindowChars = newValue }
  }

  var skipPostProcessingWithLivePolish: Bool {
    get { cleanupTuning.skipPostProcessingWithLivePolish }
    set { cleanupTuning.skipPostProcessingWithLivePolish = newValue }
  }
}
