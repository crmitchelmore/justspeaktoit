import Foundation

public struct ModulateTranscriptionFeatures: Equatable, Sendable {
  public let speakerDiarization: Bool
  public let emotionSignal: Bool
  public let accentSignal: Bool
  public let piiPhiTagging: Bool

  public init(
    speakerDiarization: Bool = true,
    emotionSignal: Bool = false,
    accentSignal: Bool = false,
    piiPhiTagging: Bool = false
  ) {
    self.speakerDiarization = speakerDiarization
    self.emotionSignal = emotionSignal
    self.accentSignal = accentSignal
    self.piiPhiTagging = piiPhiTagging
  }

  public var queryItems: [URLQueryItem] {
    [
      URLQueryItem(name: "speaker_diarization", value: boolString(speakerDiarization)),
      URLQueryItem(name: "emotion_signal", value: boolString(emotionSignal)),
      URLQueryItem(name: "accent_signal", value: boolString(accentSignal)),
      URLQueryItem(name: "pii_phi_tagging", value: boolString(piiPhiTagging))
    ]
  }

  public var multipartFields: [(name: String, value: String)] {
    [
      ("speaker_diarization", boolString(speakerDiarization)),
      ("emotion_signal", boolString(emotionSignal)),
      ("accent_signal", boolString(accentSignal)),
      ("pii_phi_tagging", boolString(piiPhiTagging))
    ]
  }

  public func formattedTranscript(from utterances: [ModulateBatchUtterance], fallbackText: String) -> String {
    guard shouldLabelSpeakers(in: utterances) else { return fallbackText }
    return utterances.map { "Speaker \($0.speaker): \($0.text)" }.joined(separator: "\n")
  }

  public func segmentText(
    for utterance: ModulateBatchUtterance, within utterances: [ModulateBatchUtterance]
  ) -> String {
    if shouldLabelSpeakers(in: utterances) && utterance.speaker > 0 {
      return "Speaker \(utterance.speaker): \(utterance.text)"
    }
    return utterance.text
  }

  private func shouldLabelSpeakers(in utterances: [ModulateBatchUtterance]) -> Bool {
    speakerDiarization && Set(utterances.map(\.speaker)).count > 1
  }

  private func boolString(_ value: Bool) -> String {
    value ? "true" : "false"
  }
}
