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
  private let api: SonioxTTSAPI
  private let secureStorage: SecureAppStorage

  init(secureStorage: SecureAppStorage, session: URLSession = .shared) {
    self.secureStorage = secureStorage
    self.api = SonioxTTSAPI(session: session)
  }

  func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
    guard let apiKey = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
      !apiKey.isEmpty
    else {
      throw TTSError.apiKeyMissing(provider)
    }

    let selection = SonioxTTSCatalog.resolvedSelection(modelID: nil, voiceID: voice)
    let request = SonioxTTSRequest(
      model: selection.model,
      language: SonioxTTSCatalog.languageCode(forLocaleIdentifier: settings.language),
      voice: selection.voice,
      audioFormat: audioFormat(for: settings.format),
      sampleRate: sampleRate(for: settings.quality),
      speed: settings.speed
    )

    let data: Data
    do {
      data = try await api.synthesize(text: text, apiKey: apiKey, request: request)
    } catch let error as SonioxTTSAPIError {
      throw ttsError(for: error)
    }

    let outputURL = try await saveAudioData(data, format: settings.format)
    let duration = try await getAudioDuration(url: outputURL)

    return TTSResult(
      audioURL: outputURL,
      provider: provider,
      voice: selection.voice.providerVoiceID,
      duration: duration,
      characterCount: text.count,
      // Soniox bills the generated audio, so the measured duration is a closer
      // figure than a character estimate.
      cost: Decimal(duration / 3600) * SonioxTTSAPI.costPerHourOfSpeech
    )
  }

  func listVoices() async throws -> [TTSVoice] {
    VoiceCatalog.sonioxVoices
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    await api.validateAPIKey(key)
  }

  // MARK: - Private Helpers

  private func ttsError(for error: SonioxTTSAPIError) -> TTSError {
    switch error {
    case .unauthorized:
      return TTSError.apiKeyMissing(provider)
    case .httpError(let statusCode, let message):
      return TTSError.synthesisFailure("HTTP \(statusCode): \(message)")
    case .invalidResponse:
      return TTSError.synthesisFailure("Invalid response")
    case .textTooLong(let limit, let characterCount):
      return TTSError.synthesisFailure(
        "Soniox accepts up to \(limit) characters per request (this text is \(characterCount))"
      )
    }
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
