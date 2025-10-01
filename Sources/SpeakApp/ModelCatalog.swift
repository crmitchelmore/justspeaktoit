import Foundation

struct ModelCatalog {
  struct Option: Identifiable, Hashable {
    let id: String
    let displayName: String
    let description: String?

    init(id: String, displayName: String, description: String? = nil) {
      self.id = id
      self.displayName = displayName
      self.description = description
    }
  }

  static let customOptionID = "__model_custom__"

  static let liveTranscription: [Option] = [
    Option(
      id: "apple/local/SFSpeechRecognizer", displayName: "macOS Native (On-device)",
      description: "Uses the built-in Speech framework for immediate on-device transcripts."),
    Option(
      id: "apple/local/Dictation", displayName: "macOS Dictation",
      description: "Alternative on-device engine that mirrors system dictation."),
  ]

  static let batchTranscription: [Option] = [
    // Dedicated transcription providers (OpenAI, Rev.ai, etc.)
    Option(
      id: "openai/whisper-1", displayName: "Whisper (OpenAI)",
      description: "OpenAI's speech recognition model. Fast and accurate."),
    Option(
      id: "revai/default", displayName: "Rev.ai",
      description: "Rev.ai's speech recognition. High accuracy with speaker identification."),

    // OpenRouter multimodal models
    Option(
      id: "google/gemini-2.0-flash-001", displayName: "Gemini 2.0 Flash (OpenRouter)",
      description: "Fast multimodal model with strong shorthand transcription."),
    Option(
      id: "google/gemini-2.0-flash-lite-001",
      displayName: "Gemini 2.0 Flash Lite (OpenRouter)",
      description: "Low-latency, budget-friendly multimodal option."),
    Option(
      id: "openai/gpt-4o-audio-preview-2024-12-17",
      displayName: "GPT-4o Audio Preview (OpenRouter)",
      description: "Early-access GPT-4o variant optimised for audio understanding."),
    Option(
      id: "deepgram/nova-2", displayName: "Deepgram Nova-2",
      description: "Third-party streaming/batch model."),
    Option(
      id: "assemblyai/conformer-2", displayName: "AssemblyAI Conformer-2",
      description: "Alternative batch transcription engine."),
  ]

  static let postProcessing: [Option] = [
    Option(
      id: "openrouter/gpt-4o-mini", displayName: "GPT-4o mini (OpenRouter)",
      description: "Great balance of quality and speed."),
    Option(
      id: "openrouter/gpt-4o", displayName: "GPT-4o (OpenRouter)", description: "Flagship quality."),
    Option(
      id: "anthropic/claude-3.5-sonnet", displayName: "Claude 3.5 Sonnet",
      description: "Strong reasoning and tone preservation."),
    Option(
      id: "google/gemini-1.5-pro-latest", displayName: "Gemini 1.5 Pro",
      description: "Google's multimodal assistant."),
    Option(
      id: "mistral/mistral-large", displayName: "Mistral Large",
      description: "European alternative with low latency."),
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
