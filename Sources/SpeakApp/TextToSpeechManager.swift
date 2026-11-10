// The manager owns synthesis, playback control and the usage ledger for every
// provider; the streaming player it drives lives in TextToSpeech/TTSProgressivePlayer.swift.
// swiftlint:disable file_length
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
  /// Holds the usage ledger; a test bootstrap passes its own suite.
  private let defaults: UserDefaults
  let clients: [TTSProvider: TextToSpeechClient]
  private var audioPlayer: AVAudioPlayer?
  private let progressivePlayer = TTSProgressivePlayer()
  private var synthesisTask: Task<TTSSynthesisOutput, Error>?
  private var playbackTask: Task<Void, Never>?
  private var synthesisID = UUID()
  private let openRouterOutput = OpenRouterSpeechOutput()
  private let progressiveSpeech: OpenRouterProgressiveSpeechOption
  private let openRouterOperation: OpenRouterOperation

  typealias OpenRouterOperation = @MainActor (
    String, String, TTSSettings, OpenRouterTTSClient, TTSProgressivePlayer
  ) async throws -> TTSSynthesisOutput

  private enum SynthesisPurpose { case normal, preview }

  private struct SynthesisContext {
    let requestID: UUID
    let purpose: SynthesisPurpose
    let autoPlay: Bool
  }

  convenience init(
    appSettings: AppSettings,
    secureStorage: SecureAppStorage,
    clients: [TTSProvider: TextToSpeechClient],
    pronunciationManager: PronunciationManager? = nil,
    recordingSaver: (@MainActor (TTSResult) async throws -> Void)? = nil,
    defaults: UserDefaults = .standard
  ) {
    self.init(
      appSettings: appSettings, secureStorage: secureStorage, clients: clients,
      pronunciationManager: pronunciationManager, recordingSaver: recordingSaver,
      defaults: defaults, progressiveSpeech: .disabled
    )
  }

  init(
    appSettings: AppSettings,
    secureStorage: SecureAppStorage,
    clients: [TTSProvider: TextToSpeechClient],
    pronunciationManager: PronunciationManager? = nil,
    recordingSaver: (@MainActor (TTSResult) async throws -> Void)? = nil,
    defaults: UserDefaults = .standard,
    progressiveSpeech: OpenRouterProgressiveSpeechOption,
    openRouterOperation: @escaping OpenRouterOperation = { text, voice, settings, client, player in
      try await OpenRouterTTSPlaybackOperation.synthesize(
        text: text, voice: voice, settings: settings, client: client, player: player
      )
    }
  ) {
    self.appSettings = appSettings
    self.secureStorage = secureStorage
    self.clients = clients
    self.pronunciationManager = pronunciationManager
    self.recordingSaver = recordingSaver
    self.defaults = defaults
    self.progressiveSpeech = progressiveSpeech
    self.openRouterOperation = openRouterOperation
    loadUsageHistory()
  }

  func synthesize(
    text: String,
    voice: String? = nil,
    useSSML: Bool? = nil
  ) async throws -> TTSResult {
    try await synthesize(text: text, voice: voice, useSSML: useSSML, purpose: .normal)
  }

  private func synthesize(
    text: String, voice: String?, useSSML: Bool?, purpose: SynthesisPurpose
  ) async throws -> TTSResult {
    try Task.checkCancellation()
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
      return try await performSynthesis(
        text: text, voice: voice, useSSML: useSSML, requestID: requestID, purpose: purpose
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let ttsError = error as? TTSError ?? .synthesisFailure(error.localizedDescription)
      if synthesisID == requestID { lastError = ttsError }
      throw ttsError
    }
  }

  private func synthesisSettings(useSSML: Bool?) -> TTSSettings {
    TTSSettings(
      speed: appSettings.ttsSpeed, pitch: appSettings.ttsPitch,
      quality: appSettings.ttsQuality, format: appSettings.ttsOutputFormat,
      useSSML: useSSML ?? appSettings.ttsUseSSML,
      language: appSettings.ttsLanguageIdentifier, sonioxRegion: appSettings.sonioxTTSRegion,
      mistralModel: appSettings.mistralTTSModel
    )
  }

  func play(url: URL) async throws {
    try await play(url: url, openRouterSpeed: appSettings.ttsSpeed)
  }

  private func play(url: URL, openRouterSpeed: Double) async throws {
    stopPlayback()

    do {
      let player = try AVAudioPlayer(contentsOf: url)
      if lastResult?.provider == .openrouter, lastResult?.audioURL == url {
        player.enableRate = true
        player.rate = Self.openRouterPlaybackRate(speed: openRouterSpeed)
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
    progressivePlayer.stop()
    isPlaying = false
  }

  func pause() {
    if progressivePlayer.isActive {
      progressivePlayer.pause()
      isPlaying = false
      return
    }
    playbackTask?.cancel()
    audioPlayer?.pause()
    isPlaying = false
  }

  func resume() {
    if progressivePlayer.isActive {
      progressivePlayer.resume()
      isPlaying = true
      return
    }
    guard let audioPlayer else { return }
    isPlaying = audioPlayer.play()
    if isPlaying { monitorPlayback(audioPlayer) }
  }

  func previewVoice(_ voice: String, sampleText: String = "Hello, this is a voice preview.") async {
    do {
      _ = try await synthesize(text: sampleText, voice: voice, useSSML: false, purpose: .preview)
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
  private func performSynthesis(
    text: String, voice: String?, useSSML: Bool?, requestID: UUID, purpose: SynthesisPurpose
  ) async throws -> TTSResult {
    let effectiveVoice = migrateAndValidateVoiceID(voice ?? appSettings.defaultTTSVoice)
    let provider = TTSProvider.from(voiceID: effectiveVoice)
    guard let client = clients[provider] else { throw TTSError.providerNotAvailable(provider) }
    let settings = synthesisSettings(useSSML: useSSML)
    let processedText = applyPronunciationProcessing(text: text, provider: provider, useSSML: settings.useSSML)
    synthesisProgress = 0.5
    let autoPlay = appSettings.ttsAutoPlay
    let saveToDirectory = appSettings.ttsSaveToDirectory
    let (task, usesProgressive) = makeSynthesisTask(
      text: processedText, voice: effectiveVoice, settings: settings, client: client,
      context: SynthesisContext(requestID: requestID, purpose: purpose, autoPlay: autoPlay)
    )
    synthesisTask = task
    let output: TTSSynthesisOutput
    do {
      output = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    } catch {
      // Only the request that still owns the player may tear it down. A
      // replacement utterance has already prepared playback on the same
      // player by the time a superseded request's cleanup runs, and stopping
      // it here would silence the newer one.
      if usesProgressive, synthesisID == requestID { stopPlayback() }
      if task.isCancelled || Task.isCancelled { throw CancellationError() }
      throw error
    }
    let result = output.result
    if usesProgressive, synthesisID == requestID { isPlaying = false }
    guard synthesisID == requestID, !Task.isCancelled, !task.isCancelled else {
      // The result was never published — not played, not saved, not in
      // history — so its file belongs to nobody whatever the provider is.
      try? FileManager.default.removeItem(at: result.audioURL)
      throw CancellationError()
    }
    if !usesProgressive { stopPlayback() }
    openRouterOutput.replace(with: result)
    lastResult = result
    usageHistory.append(result)
    saveUsageHistory()
    if saveToDirectory { try? await saveToRecordingsDirectory(result: result) }
    try ensureSynthesisActive(task: task, requestID: requestID)
    synthesisProgress = 1
    if autoPlay, !output.playbackCompleted {
      try await play(url: result.audioURL, openRouterSpeed: settings.speed)
    }
    try ensureSynthesisActive(task: task, requestID: requestID)
    return result
  }

  private func makeSynthesisTask(
    text: String, voice: String, settings: TTSSettings, client: TextToSpeechClient, context: SynthesisContext
  ) -> (Task<TTSSynthesisOutput, Error>, Bool) {
    let selection = OpenRouterSpeechSelection(id: voice)
    let openRouter = client as? OpenRouterTTSClient
    let useOpenRouter = context.purpose == .normal && context.autoPlay && settings.speed.isFinite && settings.speed == 1
      && selection.map(progressiveSpeech.allows) == true && openRouter != nil
    let progressive = context.autoPlay ? client as? any ProgressiveTextToSpeechClient : nil
    let player = progressivePlayer
    let task: Task<TTSSynthesisOutput, Error>
    if useOpenRouter, let openRouter {
      task = Task { @MainActor in
        try ensureQueuedSynthesisActive(requestID: context.requestID)
        stopPlayback()
        isPlaying = true
        return try await openRouterOperation(text, voice, settings, openRouter, player)
      }
    } else if let progressive {
      task = Task { @MainActor in
        try ensureQueuedSynthesisActive(requestID: context.requestID)
        stopPlayback()
        isPlaying = true
        let result = try await player.speak(
          text: text, voice: voice, settings: settings, using: progressive
        )
        return TTSSynthesisOutput(result: result, playbackCompleted: true)
      }
    } else {
      task = Task { @MainActor in
        try ensureQueuedSynthesisActive(requestID: context.requestID)
        let result = try await client.synthesize(text: text, voice: voice, settings: settings)
        return TTSSynthesisOutput(result: result, playbackCompleted: false)
      }
    }
    return (task, useOpenRouter || progressive != nil)
  }

  // MARK: - Private Helpers

  private func ensureQueuedSynthesisActive(requestID: UUID) throws {
    try Task.checkCancellation()
    guard synthesisID == requestID else { throw CancellationError() }
  }

  private func ensureSynthesisActive(task: Task<TTSSynthesisOutput, Error>, requestID: UUID) throws {
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
    guard let data = defaults.data(forKey: "ttsUsageHistory"),
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
      defaults.set(data, forKey: "ttsUsageHistory")
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

// MARK: - Automation

extension TextToSpeechManager {
  /// The no-key on-device voice: the system voice for the current language.
  static let onDeviceVoiceID = "system/default"

  /// The voice selected in Settings, after the same migration synthesis applies.
  var selectedVoiceID: String { migrateAndValidateVoiceID(appSettings.defaultTTSVoice) }

  /// Voices `speak say` can use now, read from the app's settings and keys:
  /// on-device voices, then every voice of a provider whose key is saved.
  /// `refresh` asks providers for account voices (for `speak voices`);
  /// otherwise the offline catalogue and last listing keep speaking fast.
  /// `including` keeps an account voice ID the offline catalogue cannot name.
  func automationVoices(refresh: Bool, including requested: String? = nil) async -> [AutomationVoice] {
    var configured: Set<TTSProvider> = [.system]
    for provider in TTSProvider.allCases where provider != .system && clients[provider] != nil {
      if await hasAPIKey(for: provider) { configured.insert(provider) }
    }
    let listed = refresh
      ? await availableVoices()
      : VoiceCatalog.allVoices + voiceListing.lastKnown.values.flatMap { $0 }
    var rows = Self.onDeviceAutomationVoices()
    var seen = Set(rows.map(\.id))
    for voice in listed where voice.provider != .system && configured.contains(voice.provider) {
      guard seen.insert(voice.id).inserted else { continue }
      rows.append(automationVoice(id: voice.id, name: voice.name, provider: voice.provider))
    }
    let selected = selectedVoiceID
    for identifier in [selected, requested].compactMap({ $0 }) where !seen.contains(identifier)
      && TTSProvider.knownVoiceIDPrefixes.contains(where: { identifier.hasPrefix($0) }) {
      let provider = TTSProvider.from(voiceID: identifier)
      guard configured.contains(provider) else { continue }
      seen.insert(identifier)
      rows.append(automationVoice(id: identifier, name: identifier, provider: provider))
    }
    return rows.map { row in
      var row = row
      row.selected = row.id == selected
      return row
    }
  }

  private static func onDeviceAutomationVoices() -> [AutomationVoice] {
    let provider = TTSProvider.system
    let systemDefault = AutomationVoice(
      id: onDeviceVoiceID, name: "System default", provider: provider.rawValue,
      providerName: provider.displayName, onDevice: true
    )
    return [systemDefault] + AVSpeechSynthesisVoice.speechVoices().map { voice in
      AutomationVoice(
        id: "system/\(voice.identifier)", name: voice.name, provider: provider.rawValue,
        providerName: provider.displayName, onDevice: true
      )
    }
  }

  private func automationVoice(id: String, name: String, provider: TTSProvider) -> AutomationVoice {
    let (models, model) = automationModels(voiceID: id, provider: provider)
    return AutomationVoice(
      id: id, name: name, provider: provider.rawValue, providerName: provider.displayName,
      models: models, model: model, onDevice: provider == .system
    )
  }

  /// The Mac expresses a model as quality (OpenAI, ElevenLabs) or a model
  /// setting (Mistral); these are listed with the shared catalogue's IDs.
  private func automationModels(voiceID: String, provider: TTSProvider) -> ([String], String?) {
    let quality = appSettings.ttsQuality
    switch provider {
    case .openai:
      guard let voice = OpenAITTSCatalog.voice(forID: voiceID) else { return ([], nil) }
      let models = OpenAITTSCatalog.models.filter(voice.supports)
      let current = models.first { $0.quality == quality } ?? models.first
      return (models.map(\.desktopModelIdentifier), current?.desktopModelIdentifier)
    case .elevenlabs:
      var models: [String] = []
      for model in TTSQuality.allCases.map({ ElevenLabsTTSModels.model(for: $0).desktopModelIdentifier })
      where !models.contains(model) { models.append(model) }
      return (models, ElevenLabsTTSModels.model(for: quality).desktopModelIdentifier)
    case .mistral:
      let models = MistralTTSCatalog.models.map(\.desktopModelIdentifier)
      return (models, appSettings.mistralTTSModel.desktopModelIdentifier)
    default:
      return ([], nil)
    }
  }

  /// Synthesizes for `speak say` with the app's clients, keys, voice settings,
  /// pronunciation and usage ledger, but none of the window's playback state,
  /// auto-play or recordings copy. The caller owns the returned file.
  func synthesizeForAutomation(
    text: String, voice: String, model: String?, overrides: AutomationSpeechSettings, format: AudioFormat
  ) async throws -> TTSResult {
    guard TTSProvider.knownVoiceIDPrefixes.contains(where: { voice.hasPrefix($0) }) else {
      throw TTSError.invalidVoice(voice)
    }
    let provider = TTSProvider.from(voiceID: voice)
    guard let client = clients[provider] else { throw TTSError.providerNotAvailable(provider) }
    if provider.requiresAPIKey, !(await hasAPIKey(for: provider)) { throw TTSError.apiKeyMissing(provider) }
    // The shared catalogue knows each cloud voice's controls; the system
    // voice applies speed and pitch itself.
    if let shared = try? DesktopSpeechVoice.strictlyResolved(modelID: model, voiceID: voice) {
      try overrides.validate(for: shared)
    }
    var settings = synthesisSettings(useSSML: nil)
    settings.format = format
    if let speed = overrides.speed { settings.speed = speed }
    if let pitch = overrides.pitch { settings.pitch = pitch }
    if let quality = overrides.quality { settings.quality = quality }
    if let language = overrides.language { settings.language = language }
    // An explicit model wins over quality where quality selects the model.
    if let model { Self.apply(model: model, provider: provider, to: &settings) }
    let processed = applyPronunciationProcessing(text: text, provider: provider, useSSML: settings.useSSML)
    let result = try await client.synthesize(text: processed, voice: voice, settings: settings)
    usageHistory.append(result)
    saveUsageHistory()
    return result
  }

  private static func apply(model: String, provider: TTSProvider, to settings: inout TTSSettings) {
    switch provider {
    case .openai:
      if let match = OpenAITTSCatalog.models.first(where: { $0.desktopModelIdentifier == model }) {
        settings.quality = match.quality
      }
    case .elevenlabs:
      if let quality = TTSQuality.allCases.first(where: {
        ElevenLabsTTSModels.model(for: $0).desktopModelIdentifier == model
      }) { settings.quality = quality }
    case .mistral:
      if let match = MistralTTSCatalog.models.first(where: { $0.desktopModelIdentifier == model }) {
        settings.mistralModel = match
      }
    default:
      break
    }
  }
}
