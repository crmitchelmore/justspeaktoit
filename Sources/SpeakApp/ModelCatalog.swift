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
  enum Tag: String, Codable, CaseIterable, Hashable {
    case fast
    case cheap
    case quality
    case leading

    var displayName: String {
      switch self {
      case .fast: return "Fast"
      case .cheap: return "Cheap"
      case .quality: return "Quality"
      case .leading: return "Leading"
      }
    }
  }

  struct Pricing: Hashable {
    /// Dollars per 1M input tokens.
    let promptPerMTokens: Double
    /// Dollars per 1M output tokens.
    let completionPerMTokens: Double

    var compactDisplay: String {
      "\(Self.formatDollars(promptPerMTokens))/\(Self.formatDollars(completionPerMTokens))"
    }

    var displayName: String {
      "\(compactDisplay) / 1M"
    }

    private static func formatDollars(_ value: Double) -> String {
      if value >= 10 { return String(format: "$%.0f", value) }
      if value >= 0.1 { return String(format: "$%.2f", value) }
      if value > 0 { return String(format: "$%.3f", value) }
      return "$0"
    }
  }

  struct Option: Identifiable, Hashable {
    let id: String
    let displayName: String
    let description: String?
    let estimatedLatencyMs: Int?
    let latencyTier: LatencyTier
    let tags: [Tag]
    let pricing: Pricing?
    let contextLength: Int?

    init(
      id: String,
      displayName: String,
      description: String? = nil,
      estimatedLatencyMs: Int? = nil,
      latencyTier: LatencyTier = .medium,
      tags: [Tag] = [],
      pricing: Pricing? = nil,
      contextLength: Int? = nil
    ) {
      self.id = id
      self.displayName = displayName
      self.description = description
      self.estimatedLatencyMs = estimatedLatencyMs
      self.latencyTier = latencyTier
      self.tags = tags
      self.pricing = pricing
      self.contextLength = contextLength
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

  // Curated, static "top" set (OpenRouter) with pricing + attribute tags.
  // Pricing is based on OpenRouter's /api/v1/models at time of writing.
  static let postProcessing: [Option] = [
    // Leading fast / cheap
    Option(
      id: "openai/gpt-4o-mini",
      displayName: "GPT-4o mini",
      description: "Great balance of quality, speed, and cost.",
      estimatedLatencyMs: 500,
      latencyTier: .fast,
      tags: [.fast, .cheap],
      pricing: Pricing(promptPerMTokens: 0.15, completionPerMTokens: 0.6),
      contextLength: 128_000
    ),
    Option(
      id: "google/gemini-3-flash-preview",
      displayName: "Gemini 3 Flash (Preview)",
      description: "High-speed, high-value model for agentic workflows.",
      estimatedLatencyMs: 650,
      latencyTier: .fast,
      tags: [.fast, .leading],
      pricing: Pricing(promptPerMTokens: 0.5, completionPerMTokens: 3.0),
      contextLength: 1_048_576
    ),
    Option(
      id: "bytedance-seed/seed-1.6-flash",
      displayName: "Seed 1.6 Flash",
      description: "Ultra-fast and very cheap.",
      estimatedLatencyMs: 350,
      latencyTier: .fast,
      tags: [.fast, .cheap],
      pricing: Pricing(promptPerMTokens: 0.075, completionPerMTokens: 0.3),
      contextLength: 262_144
    ),
    Option(
      id: "anthropic/claude-haiku-4.5",
      displayName: "Claude Haiku 4.5",
      description: "Fast, reliable formatting with strong instruction following.",
      estimatedLatencyMs: 900,
      latencyTier: .fast,
      tags: [.fast],
      pricing: Pricing(promptPerMTokens: 1.0, completionPerMTokens: 5.0),
      contextLength: 200_000
    ),

    // Leading quality
    Option(
      id: "openai/gpt-5.2",
      displayName: "GPT-5.2",
      description: "Frontier-grade quality for the toughest cleanup.",
      estimatedLatencyMs: 1600,
      latencyTier: .medium,
      tags: [.quality, .leading],
      pricing: Pricing(promptPerMTokens: 1.75, completionPerMTokens: 14.0),
      contextLength: 400_000
    ),
    Option(
      id: "openai/gpt-5.2-chat",
      displayName: "GPT-5.2 Chat",
      description: "Faster GPT-5.2 variant tuned for low-latency chat.",
      estimatedLatencyMs: 900,
      latencyTier: .fast,
      tags: [.fast, .quality, .leading],
      pricing: Pricing(promptPerMTokens: 1.75, completionPerMTokens: 14.0),
      contextLength: 128_000
    ),
    Option(
      id: "anthropic/claude-sonnet-4.5",
      displayName: "Claude Sonnet 4.5",
      description: "Excellent structure + tone preservation.",
      estimatedLatencyMs: 1400,
      latencyTier: .medium,
      tags: [.quality, .leading],
      pricing: Pricing(promptPerMTokens: 3.0, completionPerMTokens: 15.0),
      contextLength: 1_000_000
    ),

    // Strong value alternatives
    Option(
      id: "minimax/minimax-m2.1",
      displayName: "MiniMax M2.1",
      description: "Strong agentic workflow model at a good price.",
      estimatedLatencyMs: 900,
      latencyTier: .fast,
      tags: [.quality],
      pricing: Pricing(promptPerMTokens: 0.3, completionPerMTokens: 1.2),
      contextLength: 204_800
    ),
    Option(
      id: "z-ai/glm-4.7",
      displayName: "GLM 4.7",
      description: "Good reasoning and stable multi-step execution.",
      estimatedLatencyMs: 1100,
      latencyTier: .medium,
      tags: [.quality],
      pricing: Pricing(promptPerMTokens: 0.4, completionPerMTokens: 1.5),
      contextLength: 202_752
    ),
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
