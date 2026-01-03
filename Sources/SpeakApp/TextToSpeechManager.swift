import Foundation
import AVFoundation
import SwiftUI

@MainActor
final class TextToSpeechManager: ObservableObject {
  @Published private(set) var isSynthesizing = false
  @Published private(set) var isPlaying = false
  @Published private(set) var synthesisProgress: Double = 0
  @Published private(set) var lastResult: TTSResult?
  @Published private(set) var lastError: TTSError?

  // Usage tracking
  @Published private(set) var usageHistory: [TTSResult] = []

  private let appSettings: AppSettings
  private let secureStorage: SecureAppStorage
  private let pronunciationManager: PronunciationManager?
  let clients: [TTSProvider: TextToSpeechClient]
  private var audioPlayer: AVAudioPlayer?

  init(
    appSettings: AppSettings,
    secureStorage: SecureAppStorage,
    clients: [TTSProvider: TextToSpeechClient],
    pronunciationManager: PronunciationManager? = nil
  ) {
    self.appSettings = appSettings
    self.secureStorage = secureStorage
    self.clients = clients
    self.pronunciationManager = pronunciationManager
    loadUsageHistory()
  }

  func synthesize(
    text: String,
    voice: String? = nil,
    useSSML: Bool? = nil
  ) async throws -> TTSResult {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TTSError.synthesisFailure("Text cannot be empty")
    }

    isSynthesizing = true
    synthesisProgress = 0
    lastError = nil
    defer {
      isSynthesizing = false
      synthesisProgress = 0
    }

    let requestedVoice = voice ?? appSettings.defaultTTSVoice
    // Migrate legacy voice IDs and validate
    let effectiveVoice = migrateAndValidateVoiceID(requestedVoice)
    let provider = TTSProvider.from(voiceID: effectiveVoice)

    guard let client = clients[provider] else {
      throw TTSError.providerNotAvailable(provider)
    }

    synthesisProgress = 0.3

    let settings = TTSSettings(
      speed: appSettings.ttsSpeed,
      pitch: appSettings.ttsPitch,
      quality: appSettings.ttsQuality,
      format: appSettings.ttsOutputFormat,
      useSSML: useSSML ?? appSettings.ttsUseSSML
    )

    synthesisProgress = 0.5

    // Apply pronunciation replacements
    let processedText = applyPronunciationProcessing(text: text, provider: provider, useSSML: settings.useSSML)

    do {
      let result = try await client.synthesize(text: processedText, voice: effectiveVoice, settings: settings)
      synthesisProgress = 0.9

      lastResult = result
      usageHistory.append(result)
      saveUsageHistory()

      // Optionally save to recordings directory
      if appSettings.ttsSaveToDirectory {
        try? await saveToRecordingsDirectory(result: result)
      }

      synthesisProgress = 1.0

      // Auto-play if enabled
      if appSettings.ttsAutoPlay {
        try await play(url: result.audioURL)
      }

      return result
    } catch let error as TTSError {
      lastError = error
      throw error
    } catch {
      let ttsError = TTSError.synthesisFailure(error.localizedDescription)
      lastError = ttsError
      throw ttsError
    }
  }

  func play(url: URL) async throws {
    stop()

    do {
      audioPlayer = try AVAudioPlayer(contentsOf: url)
      audioPlayer?.prepareToPlay()
      audioPlayer?.play()
      isPlaying = true

      // Monitor playback completion
      Task {
        while audioPlayer?.isPlaying == true {
          try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second
        }
        await MainActor.run {
          isPlaying = false
        }
      }
    } catch {
      throw TTSError.audioPlaybackFailure
    }
  }

  func stop() {
    audioPlayer?.stop()
    audioPlayer = nil
    isPlaying = false
  }

  func pause() {
    audioPlayer?.pause()
    isPlaying = false
  }

  func resume() {
    audioPlayer?.play()
    isPlaying = audioPlayer?.isPlaying ?? false
  }

  func previewVoice(_ voice: String, sampleText: String = "Hello, this is a voice preview.") async {
    do {
      _ = try await synthesize(text: sampleText, voice: voice, useSSML: false)
    } catch {
      lastError = error as? TTSError
    }
  }

  func hasAPIKey(for provider: TTSProvider) async -> Bool {
    guard provider.requiresAPIKey else { return true }

    if let key = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
      !key.isEmpty
    {
      return true
    }
    return false
  }

  func availableVoices() async -> [TTSVoice] {
    var voices: [TTSVoice] = []

    for (provider, client) in clients {
      if await hasAPIKey(for: provider) || !provider.requiresAPIKey {
        if let providerVoices = try? await client.listVoices() {
          voices.append(contentsOf: providerVoices)
        }
      }
    }

    return voices.isEmpty ? VoiceCatalog.systemVoices : voices
  }

  func estimatedCost(text: String, voice: String? = nil) -> Decimal? {
    let effectiveVoice = voice ?? appSettings.defaultTTSVoice
    let provider = TTSProvider.from(voiceID: effectiveVoice)

    let characterCount = text.count

    switch provider {
    case .elevenlabs:
      // ElevenLabs: ~$0.30 per 1000 chars for standard, varies by plan
      return Decimal(characterCount) * 0.30 / 1000.0
    case .openai:
      // OpenAI TTS pricing (2024):
      // gpt-4o-mini-tts: $0.60 per 1M chars
      // tts-1: $15 per 1M chars
      // tts-1-hd: $30 per 1M chars
      let quality = appSettings.ttsQuality
      let pricePerMillion: Decimal
      switch quality {
      case .standard: pricePerMillion = 0.60  // gpt-4o-mini-tts
      case .high: pricePerMillion = 15.0       // tts-1
      case .highest: pricePerMillion = 30.0    // tts-1-hd
      }
      return Decimal(characterCount) * pricePerMillion / 1_000_000.0
    case .azure:
      // Azure: ~$16 per 1M chars for neural voices
      return Decimal(characterCount) * 16.0 / 1_000_000.0
    case .deepgram:
      // Deepgram Aura: $0.0135 per 1000 chars
      return Decimal(characterCount) * Decimal(string: "0.0135")! / 1000.0
    case .system:
      return nil
    }
  }

  func totalCostThisMonth() -> Decimal {
    let calendar = Calendar.current
    let now = Date()
    let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!

    return usageHistory
      .filter { $0.timestamp >= startOfMonth }
      .compactMap { $0.cost }
      .reduce(0, +)
  }

  func totalCharactersThisMonth() -> Int {
    let calendar = Calendar.current
    let now = Date()
    let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!

    return usageHistory
      .filter { $0.timestamp >= startOfMonth }
      .map { $0.characterCount }
      .reduce(0, +)
  }

  func usageByProvider(since date: Date) -> [TTSProvider: Int] {
    var usage: [TTSProvider: Int] = [:]

    for result in usageHistory.filter({ $0.timestamp >= date }) {
      usage[result.provider, default: 0] += result.characterCount
    }

    return usage
  }

  // MARK: - Private Helpers

  private func migrateAndValidateVoiceID(_ voiceID: String) -> String {
    // Migration mappings for legacy voice IDs
    let legacyMappings: [String: String] = [
      "elevenlabs/rachel": "elevenlabs/21m00Tcm4TlvDq8ikWAM",
      "elevenlabs/adam": "elevenlabs/pNInz6obpgDQGcFmaJgB",
      "elevenlabs/bella": "elevenlabs/EXAVITQu4vr4xnSDxMaL",
    ]

    // Try migration first
    if let migratedID = legacyMappings[voiceID] {
      // Update the default voice setting if it was using a legacy ID
      if appSettings.defaultTTSVoice == voiceID {
        appSettings.defaultTTSVoice = migratedID
      }
      return migratedID
    }

    // Validate the voice ID. Some providers return dynamic voice IDs (not in VoiceCatalog).
    let knownPrefixes = ["elevenlabs/", "openai/", "azure/", "deepgram/", "system/"]
    if VoiceCatalog.voice(forID: voiceID) != nil || knownPrefixes.contains(where: { voiceID.hasPrefix($0) }) {
      return voiceID
    }

    // If voice doesn't exist, fall back to default
    let fallbackVoice = "openai/alloy"
    if appSettings.defaultTTSVoice == voiceID {
      appSettings.defaultTTSVoice = fallbackVoice
    }
    return fallbackVoice
  }

  private func saveToRecordingsDirectory(result: TTSResult) async throws {
    let recordingsDir = appSettings.recordingsDirectory
    let timestamp = ISO8601DateFormatter().string(from: result.timestamp)
    let filename = "tts_\(timestamp).\(result.audioURL.pathExtension)"
    let destinationURL = recordingsDir.appendingPathComponent(filename)

    try FileManager.default.copyItem(at: result.audioURL, to: destinationURL)
  }

  // MARK: - Pronunciation Processing

  /// Apply pronunciation replacements based on provider capabilities.
  private func applyPronunciationProcessing(text: String, provider: TTSProvider, useSSML: Bool) -> String {
    guard let pronunciationManager = pronunciationManager else {
      return text
    }

    if useSSML && provider.supportsSSMLPhonemes {
      // Generate SSML with phoneme tags for supported providers
      return pronunciationManager.generateSSML(for: text, provider: provider)
    } else {
      // Use simple text replacement for other providers
      return pronunciationManager.applyReplacements(to: text)
    }
  }

  private func loadUsageHistory() {
    guard let data = UserDefaults.standard.data(forKey: "ttsUsageHistory"),
      let history = try? JSONDecoder().decode([TTSUsageRecord].self, from: data)
    else {
      return
    }

    // Convert records to results (without audio URLs since they're temporary)
    usageHistory = history.map { record in
      TTSResult(
        audioURL: URL(fileURLWithPath: "/dev/null"),  // Placeholder
        provider: record.provider,
        voice: record.voice,
        duration: record.duration,
        characterCount: record.characterCount,
        cost: record.cost,
        timestamp: record.timestamp
      )
    }
  }

  private func saveUsageHistory() {
    let records = usageHistory.map { result in
      TTSUsageRecord(
        provider: result.provider,
        voice: result.voice,
        duration: result.duration,
        characterCount: result.characterCount,
        cost: result.cost,
        timestamp: result.timestamp
      )
    }

    if let data = try? JSONEncoder().encode(records) {
      UserDefaults.standard.set(data, forKey: "ttsUsageHistory")
    }
  }
}

// MARK: - Usage Record (for persistence)

private struct TTSUsageRecord: Codable {
  let provider: TTSProvider
  let voice: String
  let duration: TimeInterval
  let characterCount: Int
  let cost: Decimal?
  let timestamp: Date
}
