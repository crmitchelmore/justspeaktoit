import Foundation

public struct ModulateBatchUtterance: Codable, Equatable, Sendable {
  public let utteranceUUID: UUID?
  public let text: String
  public let startMs: Int
  public let durationMs: Int
  public let speaker: Int
  public let language: String
  public let emotion: String?
  public let accent: String?

  public init(
    utteranceUUID: UUID?, text: String, startMs: Int, durationMs: Int, speaker: Int,
    language: String, emotion: String?, accent: String?
  ) {
    self.utteranceUUID = utteranceUUID
    self.text = text
    self.startMs = startMs
    self.durationMs = durationMs
    self.speaker = speaker
    self.language = language
    self.emotion = emotion
    self.accent = accent
  }

  enum CodingKeys: String, CodingKey {
    case utteranceUUID = "utterance_uuid"
    case text
    case startMs = "start_ms"
    case durationMs = "duration_ms"
    case speaker
    case language
    case emotion
    case accent
  }
}
