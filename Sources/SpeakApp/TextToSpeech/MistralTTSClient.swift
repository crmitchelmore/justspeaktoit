import SpeakCore
import AVFoundation
import Foundation

/// Mistral Voxtral TTS client.
///
/// HTTP transport lives in `SpeakCore.MistralTTSAPI` and the model list in
/// `SpeakCore.MistralTTSCatalog`; this wrapper adds keychain lookup, request
/// chunking, file handling and cost tracking. One Mistral key covers Voxtral
/// transcription and Voxtral speech generation.
///
/// Mistral publishes no preset voice identifiers, so the picker is populated
/// from the account's own `GET /v1/audio/voices` listing. That is also the only
/// point at which a Voxtral voice could be spoken, so nothing unusable is ever
/// offered.
actor MistralTTSClient: TextToSpeechClient {
  let provider: TTSProvider = .mistral
  private let api: MistralTTSAPI
  private let secureStorage: SecureAppStorage

  init(secureStorage: SecureAppStorage, session: URLSession = .shared) {
    self.secureStorage = secureStorage
    self.api = MistralTTSAPI(session: session)
  }

  func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
    let segments = TTSTextChunker.chunks(
      text,
      maximumCharacters: MistralTTSAPI.maxInputCharacters
    )
    guard !segments.isEmpty else {
      throw TTSError.synthesisFailure("There is no text to speak")
    }
    if let unsupported = Self.unsupportedSettingsMessage(settings) {
      throw TTSError.synthesisFailure(unsupported)
    }
    guard let apiKey = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
      !apiKey.isEmpty
    else {
      throw TTSError.apiKeyMissing(provider)
    }

    let format = Self.effectiveFormat(for: settings.format)
    let request = MistralTTSRequest(
      voiceID: voice,
      responseFormat: Self.responseFormat(for: format)
    )

    var partURLs: [URL] = []
    var duration: TimeInterval = 0
    do {
      for segment in segments {
        let data = try await api.synthesize(input: segment, apiKey: apiKey, request: request)
        let partURL = try saveAudioData(data, format: format)
        partURLs.append(partURL)
        duration += try await getAudioDuration(url: partURL)
      }
    } catch let error as MistralTTSAPIError {
      TTSAudioJoiner.discard(partURLs)
      throw Self.ttsError(for: error)
    } catch {
      TTSAudioJoiner.discard(partURLs)
      throw error
    }

    let outputURL = try TTSAudioJoiner.join(partURLs, format: format)
    // Only what was actually submitted is billed: the chunker drops the
    // surrounding whitespace, so `text.count` would over-report usage.
    let spokenCharacters = segments.reduce(0) { $0 + $1.count }
    let cost = Decimal(spokenCharacters) * MistralTTSAPI.estimatedCostPerThousandCharacters / 1000

    return TTSResult(
      audioURL: outputURL,
      provider: provider,
      voice: request.voiceID,
      duration: duration,
      characterCount: spokenCharacters,
      cost: cost
    )
  }

  func listVoices() async throws -> [TTSVoice] {
    guard let apiKey = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
      !apiKey.isEmpty
    else {
      return []
    }
    let voices = try await api.listVoices(apiKey: apiKey)
    return voices.map { voice in
      TTSVoice(
        id: voice.providerVoiceID,
        name: voice.displayName,
        provider: .mistral,
        traits: Self.traits(for: voice),
        previewURL: nil
      )
    }
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    await api.validateAPIKey(key)
  }

  // MARK: - Private Helpers

  static func traits(for voice: MistralTTSVoice) -> [TTSVoice.VoiceTrait] {
    var traits: [TTSVoice.VoiceTrait] = []
    switch voice.gender?.lowercased() {
    case "female": traits.append(.female)
    case "male": traits.append(.male)
    default: traits.append(.neutral)
    }
    if (voice.languages?.count ?? 0) > 1 {
      traits.append(.multilingual)
    }
    return traits
  }

  /// Voxtral has no speaking-rate or pitch parameter; delivery is steered by
  /// the text itself.
  static func unsupportedSettingsMessage(_ settings: TTSSettings) -> String? {
    var ignored: [String] = []
    if abs(settings.speed - 1.0) > 0.001 { ignored.append("speed") }
    if abs(settings.pitch) > 0.001 { ignored.append("pitch") }
    guard !ignored.isEmpty else { return nil }
    return "Mistral Voxtral voices do not support \(ignored.joined(separator: " or ")) control. "
      + "Reset it to the default, or choose another provider."
  }

  /// Voxtral returns MP3, WAV, FLAC or Opus — there is no AAC container, so an
  /// M4A preference is served as MP3 and the file is named for what it holds.
  static func effectiveFormat(for format: AudioFormat) -> AudioFormat {
    switch format {
    case .wav: return .wav
    case .mp3, .m4a: return .mp3
    }
  }

  static func responseFormat(for format: AudioFormat) -> MistralTTSResponseFormat {
    switch effectiveFormat(for: format) {
    case .wav: return .wav
    case .mp3, .m4a: return .mp3
    }
  }

  static func ttsError(for error: MistralTTSAPIError) -> TTSError {
    switch error {
    case .invalidResponse:
      return TTSError.synthesisFailure("Invalid response")
    case .emptyText:
      return TTSError.synthesisFailure("There is no text to speak")
    case .voiceRequired:
      return TTSError.invalidVoice("Choose a Mistral voice before speaking")
    case .unauthorized:
      // The status code is the deciding signal: a revoked key must point the
      // user at Settings rather than at a generic synthesis failure.
      return TTSError.apiKeyMissing(.mistral)
    case .forbidden(let message):
      // Mistral returns 403 both for a plan that excludes Voxtral TTS and for
      // text its moderation refused, and the response does not separate them.
      return TTSError.providerAccessRequired(
        .mistral,
        reason: "\(message) This is either a plan that excludes Voxtral TTS, "
          + "or text its content moderation declined."
      )
    case .rateLimited(let message):
      return TTSError.synthesisFailure("Mistral rate limit reached: \(message)")
    case .httpError(let statusCode, let message):
      return TTSError.synthesisFailure("HTTP \(statusCode): \(message)")
    }
  }

  private func saveAudioData(_ data: Data, format: AudioFormat) throws -> URL {
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
