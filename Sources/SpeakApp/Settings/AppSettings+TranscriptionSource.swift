import Foundation
import SpeakCore

/// Where capture comes from and which local model or remote mode a return to
/// each side of the transcription picker restores.
@MainActor
final class TranscriptionSourcePreferences: ObservableObject {
  private static let defaultLocalTranscriptionModel = "local/whisperkit/tiny"
  private let persistence: AppSettingsPersistence

  @Published var localTranscriptionModel: String {
    didSet {
      let normalized = Self.normalizedLocalTranscriptionModel(localTranscriptionModel)
      if normalized != localTranscriptionModel {
        localTranscriptionModel = normalized
        return
      }
      persistence.store(localTranscriptionModel, key: .localTranscriptionModel)
    }
  }

  /// The local source the user last chose, remembered while they are on the
  /// remote side so returning to Local restores it.
  @Published var rememberedLocalTranscriptionSource: AppSettings.LocalTranscriptionSource {
    didSet { persistence.store(rememberedLocalTranscriptionSource.rawValue, key: .rememberedLocalTranscriptionSource) }
  }

  /// The remote sub-mode the user last chose, remembered while they are on the
  /// local side so returning to Remote restores it.
  @Published var rememberedRemoteTranscriptionMode: AppSettings.RemoteTranscriptionMode {
    didSet { persistence.store(rememberedRemoteTranscriptionMode.rawValue, key: .rememberedRemoteTranscriptionMode) }
  }

  @Published var preferredAudioInputUID: String? {
    didSet {
      let key = ApplicationPreferenceKey.preferredAudioInputUID.rawValue
      if let value = preferredAudioInputUID, !value.isEmpty {
        persistence.defaults.set(value, forKey: key)
      } else {
        persistence.defaults.removeObject(forKey: key)
      }
    }
  }

  /// Value read from `UserDefaults`, kept verbatim until the property is first read.
  private var storedLocalStreamingModelSource: String?
  /// Cached result of validating ``storedLocalStreamingModelSource`` against the catalogue.
  private var normalizedLocalStreamingModelSource: String?

  /// Selected local streaming source, normalised against the installed catalogue on first read.
  ///
  /// Resolving the catalogue builds `LocalModelManager.shared`, whose initialiser creates
  /// directories, decodes the imported-models file and stats one marker file per catalogue
  /// model. Normalising eagerly put all of that on the launch path
  /// (`WireUp.bootstrap` -> `AppSettings.init`) before the first frame, so it is deferred until
  /// something actually reads this property.
  var localStreamingModelSource: String {
    get {
      if let normalizedLocalStreamingModelSource { return normalizedLocalStreamingModelSource }
      let catalog = AppSettings.localStreamingCatalogProvider()
      let stored = storedLocalStreamingModelSource ?? ""
      let normalized = catalog.supportedIDs.contains(stored) ? stored : catalog.defaultID
      normalizedLocalStreamingModelSource = normalized
      return normalized
    }
    set {
      objectWillChange.send()
      storedLocalStreamingModelSource = newValue
      normalizedLocalStreamingModelSource = newValue
      persistence.store(newValue, key: .localStreamingModelSource)
    }
  }

  /// `transcriptionMode` is the mode loaded at launch; it picks the remembered
  /// side for installs that predate remembering it.
  init(persistence: AppSettingsPersistence, transcriptionMode: AppSettings.TranscriptionMode) {
    self.persistence = persistence
    let defaults = persistence.defaults
    localTranscriptionModel = Self.normalizedLocalTranscriptionModel(
      defaults.string(forKey: ApplicationPreferenceKey.localTranscriptionModel.rawValue)
    )
    rememberedLocalTranscriptionSource =
      AppSettings.LocalTranscriptionSource(
        rawValue: defaults.string(forKey: ApplicationPreferenceKey.rememberedLocalTranscriptionSource.rawValue) ?? ""
      ) ?? (transcriptionMode == .localModel ? .downloaded : .apple)
    rememberedRemoteTranscriptionMode =
      AppSettings.RemoteTranscriptionMode(
        rawValue: defaults.string(forKey: ApplicationPreferenceKey.rememberedRemoteTranscriptionMode.rawValue) ?? ""
      ) ?? (transcriptionMode == .batchRemote ? .batch : .streaming)
    preferredAudioInputUID = defaults.string(forKey: ApplicationPreferenceKey.preferredAudioInputUID.rawValue)
    // Kept raw here; validated against the local model catalogue on first read so launch never
    // builds `LocalModelManager.shared`.
    storedLocalStreamingModelSource = defaults.string(
      forKey: ApplicationPreferenceKey.localStreamingModelSource.rawValue
    )
  }

  func reload(from restored: TranscriptionSourcePreferences) {
    rememberedLocalTranscriptionSource = restored.rememberedLocalTranscriptionSource
    rememberedRemoteTranscriptionMode = restored.rememberedRemoteTranscriptionMode
    localTranscriptionModel = restored.localTranscriptionModel
    preferredAudioInputUID = restored.preferredAudioInputUID
    localStreamingModelSource = restored.localStreamingModelSource
  }

  private static func normalizedLocalTranscriptionModel(_ identifier: String?) -> String {
    let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return defaultLocalTranscriptionModel }
    return LocalModelManager.normalizedLocalModelID(trimmed)
  }
}

extension AppSettings {
  var localTranscriptionModel: String {
    get { transcriptionSource.localTranscriptionModel }
    set { transcriptionSource.localTranscriptionModel = newValue }
  }

  var rememberedLocalTranscriptionSource: LocalTranscriptionSource {
    get { transcriptionSource.rememberedLocalTranscriptionSource }
    set { transcriptionSource.rememberedLocalTranscriptionSource = newValue }
  }

  var rememberedRemoteTranscriptionMode: RemoteTranscriptionMode {
    get { transcriptionSource.rememberedRemoteTranscriptionMode }
    set { transcriptionSource.rememberedRemoteTranscriptionMode = newValue }
  }

  var preferredAudioInputUID: String? {
    get { transcriptionSource.preferredAudioInputUID }
    set { transcriptionSource.preferredAudioInputUID = newValue }
  }

  var localStreamingModelSource: String {
    get { transcriptionSource.localStreamingModelSource }
    set { transcriptionSource.localStreamingModelSource = newValue }
  }
}
