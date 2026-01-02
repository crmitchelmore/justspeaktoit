import Foundation

enum LatencyTier: String, Codable, CaseIterable, Comparable {
  case instant
  case fast
  case medium
  case slow

  var displayName: String {
    switch self {
    case .instant: return "Instant"
    case .fast: return "Fast"
    case .medium: return "Medium"
    case .slow: return "Slow"
    }
  }

  private var sortOrder: Int {
    switch self {
    case .instant: return 0
    case .fast: return 1
    case .medium: return 2
    case .slow: return 3
    }
  }

  static func < (lhs: LatencyTier, rhs: LatencyTier) -> Bool {
    lhs.sortOrder < rhs.sortOrder
  }
}

struct ModelCatalog {
  struct Option: Identifiable, Hashable {
    let id: String
    let displayName: String
    let description: String?
    let estimatedLatencyMs: Int?
    let latencyTier: LatencyTier

    init(
      id: String,
      displayName: String,
      description: String? = nil,
      estimatedLatencyMs: Int? = nil,
      latencyTier: LatencyTier = .medium
    ) {
      self.id = id
      self.displayName = displayName
      self.description = description
      self.estimatedLatencyMs = estimatedLatencyMs
      self.latencyTier = latencyTier
    }
  }

  static let customOptionID = "__model_custom__"

  static let liveTranscription: [Option] = [
    Option(
      id: "apple/local/SFSpeechRecognizer", displayName: "macOS Native (On-device)",
      description: "Uses the built-in Speech framework for immediate on-device transcripts.",
      estimatedLatencyMs: 50, latencyTier: .instant),
    Option(
      id: "apple/local/Dictation", displayName: "macOS Dictation",
      description: "Alternative on-device engine that mirrors system dictation.",
      estimatedLatencyMs: 100, latencyTier: .instant),
    Option(
      id: "deepgram/nova-2-streaming", displayName: "Deepgram Nova-2 (Streaming)",
      description: "Real-time WebSocket streaming transcription with interim results.",
      estimatedLatencyMs: 200, latencyTier: .fast),
  ]

  static let batchTranscription: [Option] = [
    // Dedicated transcription providers (OpenAI, Rev.ai, etc.)
    Option(
      id: "openai/whisper-1", displayName: "Whisper (OpenAI)",
      description: "OpenAI's speech recognition model. Fast and accurate.",
      estimatedLatencyMs: 800, latencyTier: .fast),
    Option(
      id: "revai/default", displayName: "Rev.ai",
      description: "Rev.ai's speech recognition. High accuracy with speaker identification.",
      estimatedLatencyMs: 1500, latencyTier: .medium),

    // OpenRouter multimodal models
    Option(
      id: "google/gemini-2.0-flash-001", displayName: "Gemini 2.0 Flash (OpenRouter)",
      description: "Fast multimodal model with strong shorthand transcription.",
      estimatedLatencyMs: 600, latencyTier: .fast),
    Option(
      id: "google/gemini-2.0-flash-lite-001",
      displayName: "Gemini 2.0 Flash Lite (OpenRouter)",
      description: "Low-latency, budget-friendly multimodal option.",
      estimatedLatencyMs: 400, latencyTier: .fast),
    Option(
      id: "openai/gpt-4o-audio-preview-2024-12-17",
      displayName: "GPT-4o Audio Preview (OpenRouter)",
      description: "Early-access GPT-4o variant optimised for audio understanding.",
      estimatedLatencyMs: 2000, latencyTier: .medium),
    Option(
      id: "deepgram/nova-2", displayName: "Deepgram Nova-2",
      description: "Third-party streaming/batch model.",
      estimatedLatencyMs: 500, latencyTier: .fast),
    Option(
      id: "assemblyai/conformer-2", displayName: "AssemblyAI Conformer-2",
      description: "Alternative batch transcription engine.",
      estimatedLatencyMs: 1800, latencyTier: .medium),
  ]

  static let postProcessing: [Option] = [
    Option(
      id: "openai/gpt-4o-mini", displayName: "GPT-4o mini (OpenAI via OpenRouter)",
      description: "Great balance of quality and speed.",
      estimatedLatencyMs: 500, latencyTier: .fast),
    Option(
      id: "openai/gpt-4o", displayName: "GPT-4o (OpenAI via OpenRouter)",
      description: "Flagship quality.",
      estimatedLatencyMs: 1200, latencyTier: .medium),
    Option(
      id: "anthropic/claude-3.5-sonnet", displayName: "Claude 3.5 Sonnet",
      description: "Strong reasoning and tone preservation.",
      estimatedLatencyMs: 1500, latencyTier: .medium),
    Option(
      id: "google/gemini-1.5-pro-latest", displayName: "Gemini 1.5 Pro",
      description: "Google's multimodal assistant.",
      estimatedLatencyMs: 2500, latencyTier: .slow),
    Option(
      id: "mistral/mistral-large", displayName: "Mistral Large",
      description: "European alternative with low latency.",
      estimatedLatencyMs: 700, latencyTier: .fast),
  ]

  static var allOptions: [Option] {
    liveTranscription + batchTranscription + postProcessing
  }

  static func friendlyName(for identifier: String) -> String {
    let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "—" }

    if let exact = allOptions.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }
    ) {
      return exact.displayName
    }

    let lowercased = trimmed.lowercased()
    if lowercased.hasPrefix("apple/local") {
      return "macOS Native"
    }
    if lowercased.contains("whisper") {
      return "Whisper (\(trimmed))"
    }
    if let lastComponent = trimmed.split(separator: "/").last {
      return String(lastComponent).replacingOccurrences(of: "-", with: " ").capitalized
    }
    return trimmed
  }
}
