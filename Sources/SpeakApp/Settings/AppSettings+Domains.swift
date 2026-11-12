import AppKit
import Combine
import Foundation

/// The self-contained preference stores `AppSettings` owns: created together
/// from one persistence, reloaded together after a migration and observed as
/// one change stream. Each store keeps its own published values and writes.
@MainActor
final class AppSettingsDomains {
  let textToSpeech: TextToSpeechPreferences
  let feedback: FeedbackPreferences
  let cleanupTuning: CleanupTuningPreferences
  let transcriptionTuning: TranscriptionTuningPreferences
  let transcriptionSource: TranscriptionSourcePreferences
  let dictationBehaviour: DictationBehaviourPreferences
  let integrations: IntegrationPreferences
  let shell: ShellPreferences

  init(
    persistence: AppSettingsPersistence,
    transcriptionMode: AppSettings.TranscriptionMode,
    setActivationPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void
  ) {
    textToSpeech = TextToSpeechPreferences(persistence: persistence)
    feedback = FeedbackPreferences(persistence: persistence)
    cleanupTuning = CleanupTuningPreferences(persistence: persistence)
    transcriptionTuning = TranscriptionTuningPreferences(persistence: persistence)
    transcriptionSource = TranscriptionSourcePreferences(persistence: persistence, transcriptionMode: transcriptionMode)
    dictationBehaviour = DictationBehaviourPreferences(persistence: persistence)
    integrations = IntegrationPreferences(persistence: persistence)
    shell = ShellPreferences(persistence: persistence, setActivationPolicy: setActivationPolicy)
  }

  func reload(from restored: AppSettingsDomains) {
    textToSpeech.reload(from: restored.textToSpeech)
    feedback.reload(from: restored.feedback)
    cleanupTuning.reload(from: restored.cleanupTuning)
    transcriptionTuning.reload(from: restored.transcriptionTuning)
    transcriptionSource.reload(from: restored.transcriptionSource)
    dictationBehaviour.reload(from: restored.dictationBehaviour)
    integrations.reload(from: restored.integrations)
    shell.reload(from: restored.shell)
  }

  /// Fires immediately before any store's published value changes.
  var willChange: Publishers.MergeMany<ObservableObjectPublisher> {
    Publishers.MergeMany(
      textToSpeech.objectWillChange, feedback.objectWillChange, cleanupTuning.objectWillChange,
      transcriptionTuning.objectWillChange, transcriptionSource.objectWillChange,
      dictationBehaviour.objectWillChange, integrations.objectWillChange, shell.objectWillChange
    )
  }
}

extension AppSettings {
  var textToSpeech: TextToSpeechPreferences { domains.textToSpeech }
  var feedback: FeedbackPreferences { domains.feedback }
  var cleanupTuning: CleanupTuningPreferences { domains.cleanupTuning }
  var transcriptionTuning: TranscriptionTuningPreferences { domains.transcriptionTuning }
  var transcriptionSource: TranscriptionSourcePreferences { domains.transcriptionSource }
  var dictationBehaviour: DictationBehaviourPreferences { domains.dictationBehaviour }
  var integrations: IntegrationPreferences { domains.integrations }
  var shell: ShellPreferences { domains.shell }
}
