import Foundation

// @Implement: This file should define protocols for LLM interactions, including audio transcription and chat functionalities

struct ChatMessage: Codable, Hashable, Identifiable {
  enum Role: String, Codable {
    case system
    case user
    case assistant
  }

  let id: UUID
  let role: Role
  let content: String

  init(id: UUID = UUID(), role: Role, content: String) {
    self.id = id
    self.role = role
    self.content = content
  }
}

struct ChatCostBreakdown: Codable, Hashable {
  let inputTokens: Int
  let outputTokens: Int
  let totalCost: Decimal
  let currency: String
}

struct ChatResponse: Codable, Hashable {
  let messages: [ChatMessage]
  let finishReason: String
  let cost: ChatCostBreakdown?
  let rawPayload: String?
}

protocol ChatLLMClient {
  func sendChat(systemPrompt: String?, messages: [ChatMessage], model: String, temperature: Double)
    async throws -> ChatResponse
}

struct TranscriptionSegment: Codable, Hashable, Identifiable {
  let id: UUID
  let startTime: TimeInterval
  let endTime: TimeInterval
  let text: String
  let isFinal: Bool
  let confidence: Double?

  init(
    id: UUID = UUID(),
    startTime: TimeInterval,
    endTime: TimeInterval,
    text: String,
    isFinal: Bool = true,
    confidence: Double? = nil
  ) {
    self.id = id
    self.startTime = startTime
    self.endTime = endTime
    self.text = text
    self.isFinal = isFinal
    self.confidence = confidence
  }
}

struct TranscriptionDebugInfo: Codable, Hashable {
  let endpoint: URL
  let requestHeaders: [String: String]
  let requestBodyPreview: String
  let responseCode: Int
  let responseHeaders: [String: String]
  let responseBodyPreview: String
}

struct TranscriptionResult: Codable, Hashable {
  let text: String
  let segments: [TranscriptionSegment]
  let confidence: Double?
  let duration: TimeInterval
  let modelIdentifier: String
  let cost: ChatCostBreakdown?
  let rawPayload: String?
  let debugInfo: TranscriptionDebugInfo?
}

protocol BatchTranscriptionClient {
  func transcribeFile(at url: URL, model: String, language: String?) async throws
    -> TranscriptionResult
}

struct LiveTranscriptionUpdate {
  let text: String
  let isFinal: Bool
  let confidence: Double?

  init(text: String, isFinal: Bool = false, confidence: Double? = nil) {
    self.text = text
    self.isFinal = isFinal
    self.confidence = confidence
  }
}

@MainActor
protocol LiveTranscriptionSessionDelegate: AnyObject {
  func liveTranscriber(_ session: any LiveTranscriptionController, didUpdatePartial text: String)
  func liveTranscriber(
    _ session: any LiveTranscriptionController,
    didUpdateWith update: LiveTranscriptionUpdate
  )
  func liveTranscriber(
    _ session: any LiveTranscriptionController, didFinishWith result: TranscriptionResult)
  func liveTranscriber(_ session: any LiveTranscriptionController, didFail error: Error)
}

@MainActor
protocol LiveTranscriptionController: AnyObject {
  var delegate: LiveTranscriptionSessionDelegate? { get set }
  var isRunning: Bool { get }
  func configure(language: String?, model: String)
  func start() async throws
  func stop() async
}
