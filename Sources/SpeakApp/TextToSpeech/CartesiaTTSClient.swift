import SpeakCore
import AVFoundation
import Foundation

/// Cartesia Sonic 3.6 TTS client — low-latency speech generation from the
/// `/tts/bytes` endpoint.
///
/// HTTP transport lives in `SpeakCore.CartesiaTTSAPI` and the voice list in
/// `SpeakCore.CartesiaTTSCatalog`; this wrapper adds keychain lookup, file
/// handling and cost tracking. The Cartesia key is shared with Ink
/// transcription, so a user who already dictates with Cartesia gets voices with
/// no extra setup.
actor CartesiaTTSClient: TextToSpeechClient {
  let provider: TTSProvider = .cartesia
  private let api: CartesiaTTSAPI
  private let secureStorage: SecureAppStorage

  init(secureStorage: SecureAppStorage, session: URLSession = .shared) {
    self.secureStorage = secureStorage
    self.api = CartesiaTTSAPI(session: session)
  }

  func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
    guard let apiKey = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
      !apiKey.isEmpty
    else {
      throw TTSError.apiKeyMissing(provider)
    }

    let format = Self.effectiveFormat(for: settings.format)
    let request = CartesiaTTSRequest(
      voiceID: voice,
      outputFormat: Self.outputFormat(format: format, quality: settings.quality),
      languageIdentifier: settings.language,
      content: text,
      speed: settings.speed
    )

    let data: Data
    do {
      data = try await api.synthesize(transcript: text, apiKey: apiKey, request: request)
    } catch let error as CartesiaTTSAPIError {
      throw Self.ttsError(for: error)
    }

    let outputURL = try saveAudioData(data, format: format)
    let duration = try await getAudioDuration(url: outputURL)
    let cost = Decimal(text.count) * CartesiaTTSAPI.estimatedCostPerThousandCharacters / 1000

    return TTSResult(
      audioURL: outputURL,
      provider: provider,
      voice: request.voiceID,
      duration: duration,
      characterCount: text.count,
      cost: cost
    )
  }

  func listVoices() async throws -> [TTSVoice] {
    guard let apiKey = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
      !apiKey.isEmpty
    else {
      return VoiceCatalog.cartesiaVoices
    }
    // The library call is best-effort: the built-in catalogue keeps the picker
    // usable when Cartesia is unreachable.
    guard let remoteVoices = try? await api.listVoices(apiKey: apiKey), !remoteVoices.isEmpty else {
      return VoiceCatalog.cartesiaVoices
    }

    let builtInIDs = Set(VoiceCatalog.cartesiaVoices.map(\.id))
    return VoiceCatalog.cartesiaVoices + remoteVoices
      .filter { !builtInIDs.contains($0.providerVoiceID) }
      .map { voice in
        TTSVoice(
          id: voice.providerVoiceID,
          name: voice.name,
          provider: .cartesia,
          traits: [.multilingual, .lowLatency],
          previewURL: nil
        )
      }
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    await api.validateAPIKey(key)
  }

  // MARK: - Private Helpers

  static func ttsError(for error: CartesiaTTSAPIError) -> TTSError {
    switch error {
    case .invalidResponse:
      return TTSError.synthesisFailure("Invalid response")
    case .unauthorized:
      // The status code is the deciding signal: a revoked key must point the
      // user at Settings rather than at a generic synthesis failure.
      return TTSError.apiKeyMissing(.cartesia)
    case .quotaExceeded(let message):
      return TTSError.synthesisFailure("Cartesia credits exhausted: \(message)")
    case .rateLimited(let message):
      return TTSError.synthesisFailure("Cartesia rate limit reached: \(message)")
    case .httpError(let statusCode, let message):
      return TTSError.synthesisFailure("HTTP \(statusCode): \(message)")
    }
  }

  /// Cartesia returns WAV, MP3 or raw PCM — there is no AAC container, so an
  /// M4A preference is served as MP3 and the file is named for what it holds.
  static func effectiveFormat(for format: AudioFormat) -> AudioFormat {
    switch format {
    case .wav: return .wav
    case .mp3, .m4a: return .mp3
    }
  }

  static func outputFormat(format: AudioFormat, quality: TTSQuality) -> CartesiaTTSOutputFormat {
    let sampleRate = sampleRate(for: quality)
    switch effectiveFormat(for: format) {
    case .wav: return .wav(sampleRate: sampleRate)
    case .mp3, .m4a: return .mp3(sampleRate: sampleRate)
    }
  }

  static func sampleRate(for quality: TTSQuality) -> Int {
    switch quality {
    case .standard: return 16_000
    case .high: return 24_000
    case .highest: return 48_000
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
