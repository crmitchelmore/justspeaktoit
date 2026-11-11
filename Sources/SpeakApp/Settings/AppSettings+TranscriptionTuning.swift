import Foundation
import SpeakCore

/// Provider-specific transcription options and the timing around a stop.
@MainActor
final class TranscriptionTuningPreferences: ObservableObject {
  private let persistence: AppSettingsPersistence

  @Published var assemblyAIIgnoredPronunciationTerms: [String] {
    didSet { persistence.store(assemblyAIIgnoredPronunciationTerms, key: .assemblyAIIgnoredPronunciationTerms) }
  }

  @Published var modulateSpeakerDiarizationEnabled: Bool {
    didSet { persistence.store(modulateSpeakerDiarizationEnabled, key: .modulateSpeakerDiarization) }
  }

  @Published var modulateEmotionSignalEnabled: Bool {
    didSet { persistence.store(modulateEmotionSignalEnabled, key: .modulateEmotionSignal) }
  }

  @Published var modulateAccentSignalEnabled: Bool {
    didSet { persistence.store(modulateAccentSignalEnabled, key: .modulateAccentSignal) }
  }

  @Published var modulatePIIPhiTaggingEnabled: Bool {
    didSet { persistence.store(modulatePIIPhiTaggingEnabled, key: .modulatePIIPhiTagging) }
  }

  @Published var postRecordingTailDuration: TimeInterval {
    didSet { persistence.store(postRecordingTailDuration, key: .postRecordingTailDuration) }
  }

  /// Extra grace period (in seconds) the live controllers wait, on top of
  /// each provider's hard-coded `postStopFinalizeBudget`, before tearing the
  /// stream down. Useful when the user wants to capture the final word that
  /// some providers (notably Deepgram) only finalise a beat after the audio
  /// stops. Applied uniformly to every live transcription provider.
  @Published var liveStopGracePeriod: TimeInterval {
    didSet { persistence.store(liveStopGracePeriod, key: .liveStopGracePeriod) }
  }

  init(persistence: AppSettingsPersistence) {
    self.persistence = persistence
    let defaults = persistence.defaults
    assemblyAIIgnoredPronunciationTerms = persistence.strings(.assemblyAIIgnoredPronunciationTerms)
    modulateSpeakerDiarizationEnabled = persistence.flag(.modulateSpeakerDiarization, default: true)
    modulateEmotionSignalEnabled = persistence.flag(.modulateEmotionSignal, default: false)
    modulateAccentSignalEnabled = persistence.flag(.modulateAccentSignal, default: false)
    modulatePIIPhiTaggingEnabled = persistence.flag(.modulatePIIPhiTagging, default: false)
    postRecordingTailDuration =
      persistence.number(.postRecordingTailDuration, default: SpeechDefaults.recordingTailDuration)
    // Migration: reuse the legacy `deepgramStopGracePeriod` value the first
    // time the user launches a build that has the generic
    // `liveStopGracePeriod`. After this, the legacy key is left intact (not
    // deleted) so a downgrade still has its setting; only the new key is
    // written from now on.
    if let stored = defaults.object(forKey: ApplicationPreferenceKey.liveStopGracePeriod.rawValue) as? Double {
      liveStopGracePeriod = stored
    } else {
      let legacy = defaults.object(forKey: ApplicationPreferenceKey.deepgramStopGracePeriod.rawValue) as? Double
      let migrated = legacy ?? SpeechDefaults.liveStopGracePeriod
      liveStopGracePeriod = migrated
      // `didSet` does not fire during init, so persist the migrated value
      // explicitly — otherwise the next launch would re-read the legacy key
      // and the new key would never be populated.
      defaults.set(migrated, forKey: ApplicationPreferenceKey.liveStopGracePeriod.rawValue)
    }
  }

  func reload(from restored: TranscriptionTuningPreferences) {
    assemblyAIIgnoredPronunciationTerms = restored.assemblyAIIgnoredPronunciationTerms
    modulateSpeakerDiarizationEnabled = restored.modulateSpeakerDiarizationEnabled
    modulateEmotionSignalEnabled = restored.modulateEmotionSignalEnabled
    modulateAccentSignalEnabled = restored.modulateAccentSignalEnabled
    modulatePIIPhiTaggingEnabled = restored.modulatePIIPhiTaggingEnabled
    postRecordingTailDuration = restored.postRecordingTailDuration
    liveStopGracePeriod = restored.liveStopGracePeriod
  }
}

extension AppSettings {
  var assemblyAIIgnoredPronunciationTerms: [String] {
    get { transcriptionTuning.assemblyAIIgnoredPronunciationTerms }
    set { transcriptionTuning.assemblyAIIgnoredPronunciationTerms = newValue }
  }

  var modulateSpeakerDiarizationEnabled: Bool {
    get { transcriptionTuning.modulateSpeakerDiarizationEnabled }
    set { transcriptionTuning.modulateSpeakerDiarizationEnabled = newValue }
  }

  var modulateEmotionSignalEnabled: Bool {
    get { transcriptionTuning.modulateEmotionSignalEnabled }
    set { transcriptionTuning.modulateEmotionSignalEnabled = newValue }
  }

  var modulateAccentSignalEnabled: Bool {
    get { transcriptionTuning.modulateAccentSignalEnabled }
    set { transcriptionTuning.modulateAccentSignalEnabled = newValue }
  }

  var modulatePIIPhiTaggingEnabled: Bool {
    get { transcriptionTuning.modulatePIIPhiTaggingEnabled }
    set { transcriptionTuning.modulatePIIPhiTaggingEnabled = newValue }
  }

  var postRecordingTailDuration: TimeInterval {
    get { transcriptionTuning.postRecordingTailDuration }
    set { transcriptionTuning.postRecordingTailDuration = newValue }
  }

  var liveStopGracePeriod: TimeInterval {
    get { transcriptionTuning.liveStopGracePeriod }
    set { transcriptionTuning.liveStopGracePeriod = newValue }
  }
}
