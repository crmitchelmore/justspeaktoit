import SpeakCore
import AVFoundation
import Foundation

/// Soniox TTS v2 client — expressive speech generation in 60+ languages.
///
/// HTTP transport lives in `SpeakCore.SonioxTTSAPI` and the voice list in
/// `SpeakCore.SonioxTTSCatalog`; this wrapper adds keychain lookup, file
/// handling and cost tracking. The Soniox key is shared with transcription, so
/// a user who already dictates with Soniox gets voices with no extra setup.
actor SonioxTTSClient: TextToSpeechClient {
  let provider: TTSProvider = .soniox
  private let session: URLSession
  private let secureStorage: SecureAppStorage
  private let appSettings: AppSettings
  private let voiceNameDefaultsKey = "soniox.tts.lastKnownVoiceNames"

  init(secureStorage: SecureAppStorage, appSettings: AppSettings, session: URLSession = .shared) {
    self.secureStorage = secureStorage
    self.appSettings = appSettings
    self.session = session
  }

  func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
    guard let apiKey = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
      !apiKey.isEmpty
    else {
      throw TTSError.apiKeyMissing(provider)
    }

    let api = SonioxTTSAPI(session: session, region: settings.sonioxRegion)
    let accountVoices = try await accountVoicesIfNeeded(for: voice, apiKey: apiKey, api: api)
    let resolution = SonioxTTSCatalog.resolvedVoice(
      voiceID: voice,
      accountVoices: accountVoices,
      lastKnownName: lastKnownVoiceNames()[unscopedVoiceID(voice)]
    )
    let request = makeRequest(text: text, resolution: resolution, settings: settings)

    // Soniox caps one request at 5,000 characters. Longer input becomes a
    // sequence of requests split at sentence ends, and the parts are joined
    // into the single file the caller expects.
    let segments = SonioxTTSTextChunker.chunks(text)
    guard !segments.isEmpty else {
      throw TTSError.synthesisFailure("Text cannot be empty")
    }

    var partURLs: [URL] = []
    var duration: TimeInterval = 0
    // Soniox bills the generated audio, so every part is priced from its own
    // measured duration rather than from a character estimate.
    var cost: Decimal = 0
    do {
      for segment in segments {
        let data = try await api.synthesize(text: segment, apiKey: apiKey, request: request)
        let partURL = try await saveAudioData(data, format: settings.format)
        partURLs.append(partURL)
        let partDuration = try await getAudioDuration(url: partURL)
        duration += partDuration
        cost += Decimal(partDuration / 3600) * SonioxTTSAPI.costPerHourOfSpeech
      }
    } catch let error as SonioxTTSAPIError {
      TTSAudioJoiner.discard(partURLs)
      throw ttsError(for: error)
    } catch {
      TTSAudioJoiner.discard(partURLs)
      throw error
    }

    let outputURL = try TTSAudioJoiner.join(partURLs, format: settings.format)

    return TTSResult(
      audioURL: outputURL,
      provider: provider,
      voice: resolution.providerVoiceID,
      duration: duration,
      characterCount: text.count,
      cost: cost
    )
  }

  func listVoices() async throws -> [TTSVoice] {
    guard let apiKey = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
      !apiKey.isEmpty else {
      return VoiceCatalog.sonioxVoices
    }
    let region = await MainActor.run { appSettings.sonioxTTSRegion }
    let accountVoices = try await SonioxTTSAPI(session: session, region: region)
      .listAccountVoices(apiKey: apiKey)
    rememberVoiceNames(accountVoices)
    let readyAccountVoices = accountVoices.filter {
      $0.status(for: SonioxTTSCatalog.defaultModel) == .ready
    }
    return VoiceCatalog.sonioxVoices + readyAccountVoices.map { voice in
      TTSVoice(
        id: voice.providerVoiceID,
        name: voice.name,
        provider: .soniox,
        traits: [.multilingual],
        previewURL: nil
      )
    }
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let region = await MainActor.run { appSettings.sonioxTTSRegion }
    return await SonioxTTSAPI(session: session, region: region).validateAPIKey(key)
  }

  // MARK: - Private Helpers

  private func ttsError(for error: SonioxTTSAPIError) -> TTSError {
    switch error {
    case .invalidResponse:
      return TTSError.synthesisFailure("Invalid response")
    case .textTooLong(let limit, let characterCount):
      return TTSError.synthesisFailure(
        "Soniox accepts up to \(limit) characters per request (this text is \(characterCount))"
      )
    case .apiFailure(let failure):
      // The status code decides an authentication failure when the payload
      // carries no recognised `error_type`, so a revoked key still points the
      // user at Settings instead of showing a generic synthesis failure.
      if failure.isAuthenticationFailure {
        return TTSError.apiKeyMissing(provider)
      }
      switch failure.type {
      case .voiceNotFound, .voiceNotReady:
        return TTSError.invalidVoice(failure.message)
      default:
        let requestSuffix = failure.requestID.map { " (request \($0))" } ?? ""
        return TTSError.synthesisFailure("\(failure.message)\(requestSuffix)")
      }
    }
  }

  private func makeRequest(
    text: String,
    resolution: SonioxTTSResolvedVoice,
    settings: TTSSettings
  ) -> SonioxTTSRequest {
    let language = SonioxTTSCatalog.languageCode(
      forVoiceOutputIdentifier: settings.language,
      content: text
    )
    if let accountVoice = resolution.accountVoice {
      return SonioxTTSRequest(
        language: language,
        accountVoice: accountVoice,
        audioFormat: audioFormat(for: settings.format),
        sampleRate: sampleRate(for: settings.quality),
        speed: settings.speed
      )
    }
    let voice = SonioxTTSCatalog.voice(forID: resolution.providerVoiceID)
      ?? SonioxTTSCatalog.defaultVoice(for: SonioxTTSCatalog.defaultModel)
    return SonioxTTSRequest(
      language: language,
      voice: voice,
      audioFormat: audioFormat(for: settings.format),
      sampleRate: sampleRate(for: settings.quality),
      speed: settings.speed
    )
  }

  private func accountVoicesIfNeeded(
    for voiceID: String,
    apiKey: String,
    api: SonioxTTSAPI
  ) async throws -> [SonioxTTSAccountVoice] {
    guard SonioxTTSCatalog.voice(forID: voiceID) == nil else { return [] }
    let voices = try await api.listAccountVoices(apiKey: apiKey)
    rememberVoiceNames(voices)
    return voices
  }

  private func rememberVoiceNames(_ voices: [SonioxTTSAccountVoice]) {
    var names = lastKnownVoiceNames()
    for voice in voices { names[voice.id] = voice.name }
    UserDefaults.standard.set(names, forKey: voiceNameDefaultsKey)
  }

  private func lastKnownVoiceNames() -> [String: String] {
    UserDefaults.standard.dictionary(forKey: voiceNameDefaultsKey) as? [String: String] ?? [:]
  }

  private func unscopedVoiceID(_ voiceID: String) -> String {
    voiceID.hasPrefix("soniox/") ? String(voiceID.dropFirst("soniox/".count)) : voiceID
  }

  private func audioFormat(for format: AudioFormat) -> SonioxTTSAudioFormat {
    switch format {
    case .mp3: return .mp3
    case .m4a: return .aac
    case .wav: return .wav
    }
  }

  private func sampleRate(for quality: TTSQuality) -> Int {
    switch quality {
    case .standard: return 16_000
    case .high: return 24_000
    case .highest: return 48_000
    }
  }

  private func saveAudioData(_ data: Data, format: AudioFormat) async throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
    let filename = "tts_\(UUID().uuidString).\(format.fileExtension)"
    let fileURL = tempDir.appendingPathComponent(filename)

    try data.write(to: fileURL)
    return fileURL
  }

  private func getAudioDuration(url: URL) async throws -> TimeInterval {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    return CMTimeGetSeconds(duration)
  }
}
