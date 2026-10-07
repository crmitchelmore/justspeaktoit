import Foundation
import SpeakCore

extension AppSettings {
  var liveClientOptions: LiveClientOptions {
    LiveClientOptions(
      keywords: MetaMuseVoiceTranscribe.keywords(from: transcriptionKeywords),
      assemblyAIKeyterms: Self.assemblyAIKeyterms(from: assemblyAIKeyterms),
      modulate: ModulateLiveOptions(
        speakerDiarization: modulateSpeakerDiarizationEnabled,
        emotionSignal: modulateEmotionSignalEnabled,
        accentSignal: modulateAccentSignalEnabled,
        piiPhiTagging: modulatePIIPhiTaggingEnabled
      ),
      postStopFinalizeBudget: liveModelCapabilities.postStopFinalizeBudget,
      stopGracePeriod: liveStopGracePeriod
    )
  }

  private static func assemblyAIKeyterms(from value: String) -> [String] {
    value
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}
