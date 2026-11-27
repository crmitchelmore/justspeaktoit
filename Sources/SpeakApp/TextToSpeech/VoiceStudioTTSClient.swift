import Foundation
import SpeakCore

/// Text-to-speech client for desktop local voice studios (Voicebox, VoiceStudio, GPT-SoVITS).
actor VoiceStudioTTSClient: TextToSpeechClient {
  let provider: TTSProvider = .voiceStudio
  private let appSettings: AppSettings
  private let secureStorage: SecureAppStorage
  private let session: URLSession

  private struct SynthesisPlan {
    let voice: VoiceStudioVoice
    let config: VoiceStudioConfiguration
    let apiKey: String?
    let language: String?
  }

  init(
    appSettings: AppSettings,
    secureStorage: SecureAppStorage,
    session: URLSession = .shared
  ) {
    self.appSettings = appSettings
    self.secureStorage = secureStorage
    self.session = session
  }

  func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
    let config = await MainActor.run { appSettings.voiceStudioConfiguration }
    guard config.enabled else { throw VoiceStudioError.disabled }

    let studioVoice = try Self.resolveStudioVoice(canonicalID: voice, config: config)
    let apiKey = try? await secureStorage.secret(identifier: config.apiKeyCredentialIdentifier)
    _ = try VoiceStudioEndpointPolicy.validate(
      baseURLString: config.resolvedBaseURLString,
      apiKey: apiKey
    )
    if let gptError = config.gptSoVITSValidationError() { throw gptError }

    let segments = TTSTextChunker.chunks(text, maximumCharacters: VoiceStudioAPI.maxInputCharacters)
    guard !segments.isEmpty else {
      throw TTSError.synthesisFailure("There is no text to speak")
    }

    let plan = SynthesisPlan(
      voice: studioVoice,
      config: config,
      apiKey: apiKey,
      language: Self.normalizedLanguage(from: settings)
    )
    let result = try await synthesizeSegments(segments, plan: plan)
    return TTSResult(
      audioURL: result.url,
      provider: provider,
      voice: voice,
      duration: result.duration,
      characterCount: segments.reduce(0) { $0 + $1.count },
      cost: nil
    )
  }

  func listVoices() async throws -> [TTSVoice] {
    let config = await MainActor.run { appSettings.voiceStudioConfiguration }
    guard config.enabled else { return [] }
    let apiKey = try? await secureStorage.secret(identifier: config.apiKeyCredentialIdentifier)
    let inventory = try await VoiceStudioAPI.listVoices(
      configuration: config,
      apiKey: apiKey,
      session: session
    )
    return inventory.voices.map { voice in
      TTSVoice(
        id: voice.id,
        name: "\(voice.name) (\(voice.studioKind.displayName))",
        provider: .voiceStudio,
        traits: [],
        previewURL: nil
      )
    }
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    .failure(message: "Use Test Connection in Voice Output settings to verify your local voice studio.")
  }

  private static func resolveStudioVoice(
    canonicalID: String,
    config: VoiceStudioConfiguration
  ) throws -> VoiceStudioVoice {
    guard let kind = VoiceStudioVoice.kind(forCanonicalID: canonicalID) else {
      throw TTSError.invalidVoice(canonicalID)
    }
    guard kind == config.kind else {
      throw VoiceStudioError.unsupportedCapability(kind: config.kind, capability: "voice '\(canonicalID)'")
    }
    switch kind {
    case .gptSoVITS:
      return VoiceStudioVoice.gptSoVITSDefaultVoice(language: config.gptSoVITSTextLanguage)
    case .voicebox, .voiceStudio:
      guard let remoteID = VoiceStudioVoice.remoteVoiceID(fromCanonicalID: canonicalID, kind: kind) else {
        throw TTSError.invalidVoice(canonicalID)
      }
      return VoiceStudioVoice(studioKind: kind, remoteVoiceID: remoteID, name: remoteID)
    }
  }

  private static func normalizedLanguage(from settings: TTSSettings) -> String? {
    guard let lang = settings.language?.trimmingCharacters(in: .whitespacesAndNewlines),
      !lang.isEmpty,
      lang != VoiceOutputLanguageCatalog.automaticIdentifier else {
      return nil
    }
    return lang
  }

  private func synthesizeSegments(
    _ segments: [String],
    plan: SynthesisPlan
  ) async throws -> (url: URL, duration: TimeInterval) {
    var partURLs: [URL] = []
    var totalDuration: TimeInterval = 0
    do {
      for segment in segments {
        try Task.checkCancellation()
        let normalized = try await VoiceStudioAPI.synthesize(
          text: segment,
          voice: plan.voice,
          configuration: plan.config,
          apiKey: plan.apiKey,
          language: plan.language,
          session: session
        )
        let partURL = FileManager.default.temporaryDirectory
          .appendingPathComponent("tts_\(UUID().uuidString).wav")
        try normalized.wavData.write(to: partURL, options: .atomic)
        partURLs.append(partURL)
        totalDuration += normalized.duration
      }
    } catch {
      TTSAudioJoiner.discard(partURLs)
      throw error
    }
    return (try TTSAudioJoiner.join(partURLs, format: .wav), totalDuration)
  }
}
