import Foundation

enum TTSProvider: String, Codable, CaseIterable, Identifiable {
  case elevenlabs
  case openai
  case azure
  case system

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .elevenlabs: return "ElevenLabs"
    case .openai: return "OpenAI"
    case .azure: return "Azure Cognitive Services"
    case .system: return "macOS System"
    }
  }

  var requiresAPIKey: Bool {
    switch self {
    case .system: return false
    default: return true
    }
  }

  var apiKeyIdentifier: String {
    switch self {
    case .elevenlabs: return "elevenlabs.apiKey"
    case .openai: return "openai.tts.apiKey"
    case .azure: return "azure.speech.apiKey"
    case .system: return ""
    }
  }

  static func from(voiceID: String) -> TTSProvider {
    if voiceID.hasPrefix("elevenlabs/") { return .elevenlabs }
    if voiceID.hasPrefix("openai/") { return .openai }
    if voiceID.hasPrefix("azure/") { return .azure }
    if voiceID.hasPrefix("system/") { return .system }
    return .system
  }
}

enum TTSQuality: String, Codable, CaseIterable, Identifiable {
  case standard
  case high
  case highest

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .standard: return "Standard"
    case .high: return "High"
    case .highest: return "Highest"
    }
  }
}

enum AudioFormat: String, Codable, CaseIterable, Identifiable {
  case mp3
  case m4a
  case wav

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .mp3: return "MP3"
    case .m4a: return "AAC (M4A)"
    case .wav: return "WAV"
    }
  }

  var fileExtension: String {
    rawValue
  }
}

struct TTSSettings {
  var speed: Double
  var pitch: Double
  var quality: TTSQuality
  var format: AudioFormat
  var useSSML: Bool

  init(
    speed: Double = 1.0,
    pitch: Double = 0.0,
    quality: TTSQuality = .high,
    format: AudioFormat = .mp3,
    useSSML: Bool = false
  ) {
    self.speed = speed
    self.pitch = pitch
    self.quality = quality
    self.format = format
    self.useSSML = useSSML
  }
}

struct TTSVoice: Identifiable, Hashable, Codable {
  let id: String
  let name: String
  let provider: TTSProvider
  let traits: [VoiceTrait]
  let previewURL: URL?

  var displayName: String {
    "\(name) (\(provider.displayName))"
  }

  enum VoiceTrait: String, Codable, Hashable {
    case male
    case female
    case neutral
    case american
    case british
    case australian
    case professional
    case casual
    case deep
    case clear
    case warm
    case energetic
    case builtin
  }
}

struct TTSResult {
  let audioURL: URL
  let provider: TTSProvider
  let voice: String
  let duration: TimeInterval
  let characterCount: Int
  let cost: Decimal?
  let timestamp: Date

  init(
    audioURL: URL,
    provider: TTSProvider,
    voice: String,
    duration: TimeInterval,
    characterCount: Int,
    cost: Decimal? = nil,
    timestamp: Date = Date()
  ) {
    self.audioURL = audioURL
    self.provider = provider
    self.voice = voice
    self.duration = duration
    self.characterCount = characterCount
    self.cost = cost
    self.timestamp = timestamp
  }
}

enum TTSError: LocalizedError {
  case apiKeyMissing(TTSProvider)
  case providerNotAvailable(TTSProvider)
  case invalidVoice(String)
  case synthesisFailure(String)
  case audioPlaybackFailure
  case fileImportFailure
  case networkError(Error)
  case invalidSSML(String)

  var errorDescription: String? {
    switch self {
    case .apiKeyMissing(let provider):
      return "API key missing for \(provider.displayName)"
    case .providerNotAvailable(let provider):
      return "\(provider.displayName) is not available"
    case .invalidVoice(let voice):
      return "Invalid voice: \(voice)"
    case .synthesisFailure(let message):
      return "Synthesis failed: \(message)"
    case .audioPlaybackFailure:
      return "Failed to play audio"
    case .fileImportFailure:
      return "Failed to import file"
    case .networkError(let error):
      return "Network error: \(error.localizedDescription)"
    case .invalidSSML(let message):
      return "Invalid SSML: \(message)"
    }
  }
}

protocol TextToSpeechClient {
  var provider: TTSProvider { get }

  func synthesize(
    text: String,
    voice: String,
    settings: TTSSettings
  ) async throws -> TTSResult

  func listVoices() async throws -> [TTSVoice]
  func validateAPIKey(_ key: String) async -> APIKeyValidationResult
}

struct VoiceCatalog {
  static let elevenlabsVoices: [TTSVoice] = [
    TTSVoice(
      id: "elevenlabs/21m00Tcm4TlvDq8ikWAM",
      name: "Rachel",
      provider: .elevenlabs,
      traits: [.female, .american, .professional, .clear],
      previewURL: nil
    ),
    TTSVoice(
      id: "elevenlabs/pNInz6obpgDQGcFmaJgB",
      name: "Adam",
      provider: .elevenlabs,
      traits: [.male, .american, .deep, .professional],
      previewURL: nil
    ),
    TTSVoice(
      id: "elevenlabs/EXAVITQu4vr4xnSDxMaL",
      name: "Sarah",
      provider: .elevenlabs,
      traits: [.female, .american, .warm],
      previewURL: nil
    ),
    TTSVoice(
      id: "elevenlabs/ErXwobaYiN019PkySvjV",
      name: "Antoni",
      provider: .elevenlabs,
      traits: [.male, .american, .clear],
      previewURL: nil
    ),
    TTSVoice(
      id: "elevenlabs/TxGEqnHWrfWFTfGW9XjX",
      name: "Josh",
      provider: .elevenlabs,
      traits: [.male, .american, .energetic],
      previewURL: nil
    ),
  ]

  static let openaiVoices: [TTSVoice] = [
    TTSVoice(
      id: "openai/alloy",
      name: "Alloy",
      provider: .openai,
      traits: [.neutral, .professional],
      previewURL: nil
    ),
    TTSVoice(
      id: "openai/echo",
      name: "Echo",
      provider: .openai,
      traits: [.male, .clear],
      previewURL: nil
    ),
    TTSVoice(
      id: "openai/fable",
      name: "Fable",
      provider: .openai,
      traits: [.british, .professional],
      previewURL: nil
    ),
    TTSVoice(
      id: "openai/onyx",
      name: "Onyx",
      provider: .openai,
      traits: [.male, .deep],
      previewURL: nil
    ),
    TTSVoice(
      id: "openai/nova",
      name: "Nova",
      provider: .openai,
      traits: [.female, .energetic],
      previewURL: nil
    ),
    TTSVoice(
      id: "openai/shimmer",
      name: "Shimmer",
      provider: .openai,
      traits: [.female, .warm],
      previewURL: nil
    ),
  ]

  static let azureVoices: [TTSVoice] = [
    TTSVoice(
      id: "azure/en-US-AriaNeural",
      name: "Aria",
      provider: .azure,
      traits: [.female, .american, .professional],
      previewURL: nil
    ),
    TTSVoice(
      id: "azure/en-US-GuyNeural",
      name: "Guy",
      provider: .azure,
      traits: [.male, .american, .professional],
      previewURL: nil
    ),
    TTSVoice(
      id: "azure/en-GB-SoniaNeural",
      name: "Sonia",
      provider: .azure,
      traits: [.female, .british, .professional],
      previewURL: nil
    ),
  ]

  static let systemVoices: [TTSVoice] = [
    TTSVoice(
      id: "system/samantha",
      name: "Samantha",
      provider: .system,
      traits: [.female, .american, .builtin],
      previewURL: nil
    ),
    TTSVoice(
      id: "system/alex",
      name: "Alex",
      provider: .system,
      traits: [.male, .american, .builtin],
      previewURL: nil
    ),
  ]

  static let allVoices: [TTSVoice] =
    elevenlabsVoices + openaiVoices + azureVoices + systemVoices

  static func voices(for provider: TTSProvider) -> [TTSVoice] {
    switch provider {
    case .elevenlabs: return elevenlabsVoices
    case .openai: return openaiVoices
    case .azure: return azureVoices
    case .system: return systemVoices
    }
  }

  static func voice(forID id: String) -> TTSVoice? {
    // Try direct match first
    if let voice = allVoices.first(where: { $0.id == id }) {
      return voice
    }

    // Try migrating legacy voice IDs
    let migratedID = migrateLegacyVoiceID(id)
    return allVoices.first { $0.id == migratedID }
  }

  // Migrate old voice IDs to new ones
  private static func migrateLegacyVoiceID(_ id: String) -> String {
    let legacyMappings: [String: String] = [
      "elevenlabs/rachel": "elevenlabs/21m00Tcm4TlvDq8ikWAM",
      "elevenlabs/adam": "elevenlabs/pNInz6obpgDQGcFmaJgB",
      "elevenlabs/bella": "elevenlabs/EXAVITQu4vr4xnSDxMaL",
    ]
    return legacyMappings[id] ?? id
  }
}
