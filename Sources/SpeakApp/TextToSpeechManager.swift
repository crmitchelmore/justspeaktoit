import Foundation
import AVFoundation
import SpeakCore
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

  /// The runtime voice listing: the last good result from each provider and
  /// the providers whose listing failed. Mistral publishes no offline
  /// catalogue, so a suppressed listing error would make a keyed provider
  /// vanish from the picker with nothing to explain or retry.
  @Published var voiceListing = TTSVoiceListingState()

  private let appSettings: AppSettings
  private let secureStorage: SecureAppStorage
  private let pronunciationManager: PronunciationManager?
  private let recordingSaver: (@MainActor (TTSResult) async throws -> Void)?
  let clients: [TTSProvider: TextToSpeechClient]
  private var audioPlayer: AVAudioPlayer?
  private var synthesisTask: Task<TTSResult, Error>?
  private var playbackTask: Task<Void, Never>?
  private var synthesisID = UUID()
  private let openRouterOutput = OpenRouterSpeechOutput()

  init(
    appSettings: AppSettings,
    secureStorage: SecureAppStorage,
    clients: [TTSProvider: TextToSpeechClient],
    pronunciationManager: PronunciationManager? = nil,
    recordingSaver: (@MainActor (TTSResult) async throws -> Void)? = nil
  ) {
    self.appSettings = appSettings
    self.secureStorage = secureStorage
    self.clients = clients
    self.pronunciationManager = pronunciationManager
    self.recordingSaver = recordingSaver
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

    synthesisTask?.cancel()
    let requestID = UUID()
    synthesisID = requestID
    isSynthesizing = true
    synthesisProgress = 0
    lastError = nil
    defer {
      if synthesisID == requestID {
        isSynthesizing = false
        synthesisProgress = 0
        synthesisTask = nil
      }
    }
    do {
      return try await performSynthesis(text: text, voice: voice, useSSML: useSSML, requestID: requestID)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let ttsError = error as? TTSError ?? .synthesisFailure(error.localizedDescription)
      if synthesisID == requestID { lastError = ttsError }
      throw ttsError
    }
  }

  private func performSynthesis(
    text: String, voice: String?, useSSML: Bool?, requestID: UUID
  ) async throws -> TTSResult {
    let effectiveVoice = migrateAndValidateVoiceID(voice ?? appSettings.defaultTTSVoice)
    let provider = TTSProvider.from(voiceID: effectiveVoice)
    guard let client = clients[provider] else { throw TTSError.providerNotAvailable(provider) }
    let settings = synthesisSettings(useSSML: useSSML)
    let processedText = applyPronunciationProcessing(text: text, provider: provider, useSSML: settings.useSSML)
    synthesisProgress = 0.5
    let task = Task { try await client.synthesize(text: processedText, voice: effectiveVoice, settings: settings) }
    synthesisTask = task
    let result: TTSResult
    do {
      result = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    } catch {
      if task.isCancelled || Task.isCancelled { throw CancellationError() }
      throw error
    }
    guard synthesisID == requestID, !Task.isCancelled, !task.isCancelled else {
      if result.provider == .openrouter { try? FileManager.default.removeItem(at: result.audioURL) }
      throw CancellationError()
    }
    stopPlayback()
    openRouterOutput.replace(with: result)
    lastResult = result
    usageHistory.append(result)
    saveUsageHistory()
    if appSettings.ttsSaveToDirectory { try? await saveToRecordingsDirectory(result: result) }
    try ensureSynthesisActive(task: task, requestID: requestID)
    synthesisProgress = 1
    if appSettings.ttsAutoPlay { try await play(url: result.audioURL) }
    try ensureSynthesisActive(task: task, requestID: requestID)
    return result
  }

  private func synthesisSettings(useSSML: Bool?) -> TTSSettings {
    TTSSettings(
      speed: appSettings.ttsSpeed, pitch: appSettings.ttsPitch,
      quality: appSettings.ttsQuality, format: appSettings.ttsOutputFormat,
      useSSML: useSSML ?? appSettings.ttsUseSSML,
      language: appSettings.ttsLanguageIdentifier, sonioxRegion: appSettings.sonioxTTSRegion
    )
  }

  func play(url: URL) async throws {
    stopPlayback()

    do {
      let player = try AVAudioPlayer(contentsOf: url)
      if lastResult?.provider == .openrouter, lastResult?.audioURL == url {
        player.enableRate = true
        player.rate = Self.openRouterPlaybackRate(speed: appSettings.ttsSpeed)
      }
      audioPlayer = player
      player.prepareToPlay()
      guard player.play() else { throw TTSError.audioPlaybackFailure }
      isPlaying = true
      monitorPlayback(player)
    } catch {
      throw TTSError.audioPlaybackFailure
    }
  }

  func stop() {
    synthesisID = UUID()
    isSynthesizing = false
    synthesisProgress = 0
    synthesisTask?.cancel()
    synthesisTask = nil
    stopPlayback()
  }

  private func stopPlayback() {
    playbackTask?.cancel()
    playbackTask = nil
    audioPlayer?.stop()
    audioPlayer = nil
    isPlaying = false
  }

  func pause() {
    playbackTask?.cancel()
    audioPlayer?.pause()
    isPlaying = false
  }

  func resume() {
    guard let audioPlayer else { return }
    isPlaying = audioPlayer.play()
    if isPlaying { monitorPlayback(audioPlayer) }
  }

  func previewVoice(_ voice: String, sampleText: String = "Hello, this is a voice preview.") async {
    do {
      _ = try await synthesize(text: sampleText, voice: voice, useSSML: false)
    } catch {
      lastError = error as? TTSError
    }
  }

  func openRouterAPIKey() async -> String? {
    try? await secureStorage.secret(identifier: TTSProvider.openrouter.apiKeyIdentifier)
  }

  func hasAPIKey(for provider: TTSProvider) async -> Bool {
    guard provider.requiresAPIKey else { return true }

    if let key = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
      !key.isEmpty {
      return true
    }
    return false
  }

    func estimatedCost(text: String, voice: String? = nil) -> Decimal? {
        let effectiveVoice = voice ?? appSettings.defaultTTSVoice
        return TTSProvider.from(voiceID: effectiveVoice)
            .estimatedCost(characterCount: text.count, quality: appSettings.ttsQuality, voiceID: effectiveVoice)
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

}

extension TextToSpeechManager {
  // MARK: - Private Helpers

  private func ensureSynthesisActive(task: Task<TTSResult, Error>, requestID: UUID) throws {
    guard synthesisID == requestID, !task.isCancelled, !Task.isCancelled else { throw CancellationError() }
  }

  static func openRouterPlaybackRate(speed: Double) -> Float {
    speed.isFinite ? Float(min(2, max(0.5, speed))) : 1
  }

  private func monitorPlayback(_ player: AVAudioPlayer) {
    playbackTask?.cancel()
    playbackTask = Task { [weak self, weak player] in
      while player?.isPlaying == true {
        do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
      }
      guard !Task.isCancelled, let self, self.audioPlayer === player else { return }
      self.isPlaying = self.audioPlayer?.isPlaying ?? false
    }
  }

  private func migrateAndValidateVoiceID(_ voiceID: String) -> String {
    // Migration mappings for legacy voice IDs
    let legacyMappings: [String: String] = [
      "elevenlabs/rachel": "elevenlabs/21m00Tcm4TlvDq8ikWAM",
      "elevenlabs/adam": "elevenlabs/pNInz6obpgDQGcFmaJgB",
      "elevenlabs/bella": "elevenlabs/EXAVITQu4vr4xnSDxMaL"
    ]

    // Try migration first
    if let migratedID = legacyMappings[voiceID] {
      // Update the default voice setting if it was using a legacy ID
      if appSettings.defaultTTSVoice == voiceID {
        appSettings.defaultTTSVoice = migratedID
      }
      return migratedID
    }

    // Validate the voice ID. Some providers return dynamic voice IDs (not in
    // VoiceCatalog): ElevenLabs and OpenRouter always, Mistral for every voice
    // it has, since Mistral publishes no presets. The routing prefix list is
    // the one `TTSProvider.from(voiceID:)` dispatches on, so anything that
    // routes to a real provider also survives validation.
    if VoiceCatalog.voice(forID: voiceID) != nil
      || TTSProvider.knownVoiceIDPrefixes.contains(where: { voiceID.hasPrefix($0) }) {
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
    if let recordingSaver {
      try await recordingSaver(result)
      return
    }
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

struct TTSUsageRecord: Codable {
  let provider: TTSProvider
  let voice: String
  let duration: TimeInterval
  let characterCount: Int
  let cost: Decimal?
  let timestamp: Date
}

extension TextToSpeechManager {
    func reloadAfterMigration() { loadUsageHistory() }
}
