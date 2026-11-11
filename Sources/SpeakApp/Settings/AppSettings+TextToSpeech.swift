import Foundation
import SpeakCore

/// Text-to-speech preferences: voice, language, provider options and output.
@MainActor
final class TextToSpeechPreferences: ObservableObject {
  private let persistence: AppSettingsPersistence

  @Published var defaultTTSVoice: String {
    didSet { persistence.store(defaultTTSVoice, key: .defaultTTSVoice) }
  }

  @Published var ttsLanguageIdentifier: String {
    didSet { persistence.store(ttsLanguageIdentifier, key: .ttsLanguage) }
  }

  @Published var mistralTTSModel: MistralTTSModel {
    didSet { persistence.store(mistralTTSModel.rawValue, key: .mistralTTSModel) }
  }

  @Published var sonioxTTSRegion: SonioxTTSRegion {
    didSet { persistence.store(sonioxTTSRegion.rawValue, key: .sonioxTTSRegion) }
  }

  @Published var ttsSpeed: Double {
    didSet { persistence.store(ttsSpeed, key: .ttsSpeed) }
  }

  @Published var ttsPitch: Double {
    didSet { persistence.store(ttsPitch, key: .ttsPitch) }
  }

  @Published var ttsQuality: TTSQuality {
    didSet { persistence.store(ttsQuality.rawValue, key: .ttsQuality) }
  }

  @Published var ttsOutputFormat: AudioFormat {
    didSet { persistence.store(ttsOutputFormat.rawValue, key: .ttsOutputFormat) }
  }

  @Published var ttsAutoPlay: Bool {
    didSet { persistence.store(ttsAutoPlay, key: .ttsAutoPlay) }
  }

  @Published var ttsSaveToDirectory: Bool {
    didSet { persistence.store(ttsSaveToDirectory, key: .ttsSaveToDirectory) }
  }

  @Published var ttsUseSSML: Bool {
    didSet { persistence.store(ttsUseSSML, key: .ttsUseSSML) }
  }

  /// Favorite TTS voice IDs for quick access
  @Published var ttsFavoriteVoices: [String] {
    didSet { persistence.store(ttsFavoriteVoices, key: .ttsFavoriteVoices) }
  }

  /// TTS pronunciation dictionary - maps words to phonetic spellings
  @Published var ttsPronunciationDictionary: [String: String] {
    didSet {
      if let data = try? JSONEncoder().encode(ttsPronunciationDictionary) {
        persistence.defaults.set(data, forKey: ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue)
      }
    }
  }

  init(persistence: AppSettingsPersistence) {
    self.persistence = persistence
    let defaults = persistence.defaults
    defaultTTSVoice = defaults.string(forKey: ApplicationPreferenceKey.defaultTTSVoice.rawValue) ?? "openai/alloy"
    ttsLanguageIdentifier = VoiceOutputLanguageCatalog.normalizedIdentifier(
      defaults.string(forKey: ApplicationPreferenceKey.ttsLanguage.rawValue)
    )
    mistralTTSModel = MistralTTSModel(
      rawValue: defaults.string(forKey: ApplicationPreferenceKey.mistralTTSModel.rawValue) ?? ""
    ) ?? MistralTTSCatalog.defaultModel
    sonioxTTSRegion = SonioxTTSRegion.migrated(
      from: defaults.string(forKey: ApplicationPreferenceKey.sonioxTTSRegion.rawValue)
    )
    ttsSpeed = persistence.number(.ttsSpeed, default: 1.0)
    ttsPitch = persistence.number(.ttsPitch, default: 0.0)
    ttsQuality = TTSQuality(rawValue: defaults.string(forKey: ApplicationPreferenceKey.ttsQuality.rawValue) ?? "")
      ?? .high
    ttsOutputFormat = AudioFormat(
      rawValue: defaults.string(forKey: ApplicationPreferenceKey.ttsOutputFormat.rawValue) ?? ""
    ) ?? .macDefault
    ttsAutoPlay = persistence.flag(.ttsAutoPlay, default: SpeechGenerationDefaults.autoPlay)
    ttsSaveToDirectory = persistence.flag(.ttsSaveToDirectory, default: SpeechGenerationDefaults.saveToRecordings)
    ttsUseSSML = persistence.flag(.ttsUseSSML, default: false)
    ttsFavoriteVoices = persistence.strings(.ttsFavoriteVoices)
    if let pronData = defaults.data(forKey: ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue),
      let dict = try? JSONDecoder().decode([String: String].self, from: pronData) {
      ttsPronunciationDictionary = dict
    } else {
      ttsPronunciationDictionary = [:]
    }
  }

  func reload(from restored: TextToSpeechPreferences) {
    defaultTTSVoice = restored.defaultTTSVoice
    ttsLanguageIdentifier = restored.ttsLanguageIdentifier
    mistralTTSModel = restored.mistralTTSModel
    sonioxTTSRegion = restored.sonioxTTSRegion
    ttsSpeed = restored.ttsSpeed
    ttsPitch = restored.ttsPitch
    ttsQuality = restored.ttsQuality
    ttsOutputFormat = restored.ttsOutputFormat
    ttsAutoPlay = restored.ttsAutoPlay
    ttsSaveToDirectory = restored.ttsSaveToDirectory
    ttsUseSSML = restored.ttsUseSSML
    ttsFavoriteVoices = restored.ttsFavoriteVoices
    ttsPronunciationDictionary = restored.ttsPronunciationDictionary
  }
}

extension AppSettings {
  var defaultTTSVoice: String {
    get { textToSpeech.defaultTTSVoice }
    set { textToSpeech.defaultTTSVoice = newValue }
  }

  var ttsLanguageIdentifier: String {
    get { textToSpeech.ttsLanguageIdentifier }
    set { textToSpeech.ttsLanguageIdentifier = newValue }
  }

  var mistralTTSModel: MistralTTSModel {
    get { textToSpeech.mistralTTSModel }
    set { textToSpeech.mistralTTSModel = newValue }
  }

  var sonioxTTSRegion: SonioxTTSRegion {
    get { textToSpeech.sonioxTTSRegion }
    set { textToSpeech.sonioxTTSRegion = newValue }
  }

  var ttsSpeed: Double {
    get { textToSpeech.ttsSpeed }
    set { textToSpeech.ttsSpeed = newValue }
  }

  var ttsPitch: Double {
    get { textToSpeech.ttsPitch }
    set { textToSpeech.ttsPitch = newValue }
  }

  var ttsQuality: TTSQuality {
    get { textToSpeech.ttsQuality }
    set { textToSpeech.ttsQuality = newValue }
  }

  var ttsOutputFormat: AudioFormat {
    get { textToSpeech.ttsOutputFormat }
    set { textToSpeech.ttsOutputFormat = newValue }
  }

  var ttsAutoPlay: Bool {
    get { textToSpeech.ttsAutoPlay }
    set { textToSpeech.ttsAutoPlay = newValue }
  }

  var ttsSaveToDirectory: Bool {
    get { textToSpeech.ttsSaveToDirectory }
    set { textToSpeech.ttsSaveToDirectory = newValue }
  }

  var ttsUseSSML: Bool {
    get { textToSpeech.ttsUseSSML }
    set { textToSpeech.ttsUseSSML = newValue }
  }

  var ttsFavoriteVoices: [String] {
    get { textToSpeech.ttsFavoriteVoices }
    set { textToSpeech.ttsFavoriteVoices = newValue }
  }

  var ttsPronunciationDictionary: [String: String] {
    get { textToSpeech.ttsPronunciationDictionary }
    set { textToSpeech.ttsPronunciationDictionary = newValue }
  }
}
