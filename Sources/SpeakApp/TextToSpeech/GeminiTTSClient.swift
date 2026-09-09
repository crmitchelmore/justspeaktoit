import SpeakCore
import AVFoundation
import Foundation

/// Direct Gemini speech-generation client.
///
/// HTTP transport lives in `SpeakCore.GeminiTTSAPI` and the model and voice
/// lists in `SpeakCore.GeminiTTSCatalog`; this wrapper adds keychain lookup,
/// PCM containerisation, file handling and cost tracking.
///
/// This is Google's own billing and quota, not the OpenRouter speech route
/// tracked separately: it uses the `google.apiKey` credential that already
/// powers Gemini transcription and is charged against the Gemini API account.
actor GeminiTTSClient: TextToSpeechClient {
  let provider: TTSProvider = .gemini
  private let api: GeminiTTSAPI
  private let secureStorage: SecureAppStorage

  init(secureStorage: SecureAppStorage, session: URLSession = .shared) {
    self.secureStorage = secureStorage
    self.api = GeminiTTSAPI(session: session)
  }

  func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
    let segments = TTSTextChunker.chunks(
      text,
      maximumCharacters: GeminiTTSAPI.maxInputCharacters
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

    let resolved = GeminiTTSCatalog.resolvedVoice(forID: voice)
    let request = GeminiTTSRequest(
      voiceID: resolved.providerVoiceID,
      languageIdentifier: settings.language
    )

    var partURLs: [URL] = []
    var duration: TimeInterval = 0
    do {
      for segment in segments {
        let audio = try await api.synthesize(input: segment, apiKey: apiKey, request: request)
        let partURL = try saveAudioData(audio.playableData)
        partURLs.append(partURL)
        duration += try await getAudioDuration(url: partURL)
      }
    } catch let error as GeminiTTSAPIError {
      TTSAudioJoiner.discard(partURLs)
      throw Self.ttsError(for: error)
    } catch {
      TTSAudioJoiner.discard(partURLs)
      throw error
    }

    let outputURL = try TTSAudioJoiner.join(partURLs, format: .wav)
    // Gemini bills the generated audio per token, not the submitted text, so
    // the charge is derived from the measured duration.
    let cost = Decimal(duration) * GeminiTTSCatalog.defaultModel.costPerSecondOfSpeech

    return TTSResult(
      audioURL: outputURL,
      provider: provider,
      voice: resolved.providerVoiceID,
      duration: duration,
      characterCount: text.count,
      cost: cost
    )
  }

  func listVoices() async throws -> [TTSVoice] {
    // Gemini's prebuilt voices are a fixed documented set with no listing
    // endpoint.
    VoiceCatalog.geminiVoices
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    await api.validateAPIKey(key)
  }

  // MARK: - Private Helpers

  /// Gemini steers delivery through the prompt rather than through numeric
  /// controls: there is no speaking-rate or pitch parameter.
  static func unsupportedSettingsMessage(_ settings: TTSSettings) -> String? {
    var ignored: [String] = []
    if abs(settings.speed - 1.0) > 0.001 { ignored.append("speed") }
    if abs(settings.pitch) > 0.001 { ignored.append("pitch") }
    guard !ignored.isEmpty else { return nil }
    return "Gemini voices do not support \(ignored.joined(separator: " or ")) control. "
      + "Reset it to the default, or choose another provider."
  }

  static func ttsError(for error: GeminiTTSAPIError) -> TTSError {
    switch error {
    case .invalidResponse:
      return TTSError.synthesisFailure("Invalid response")
    case .emptyText:
      return TTSError.synthesisFailure("There is no text to speak")
    case .noAudioReturned(let message):
      return TTSError.synthesisFailure("\(message). Try again.")
    case .unauthorized:
      // The status code is the deciding signal: a revoked key must point the
      // user at Settings rather than at a generic synthesis failure.
      return TTSError.apiKeyMissing(.gemini)
    case .permissionDenied(let message):
      return TTSError.providerAccessRequired(.gemini, reason: message)
    case .rateLimited(let message):
      return TTSError.synthesisFailure("Gemini quota reached: \(message)")
    case .contentBlocked(_, let message):
      return TTSError.synthesisFailure("Gemini declined this text: \(message)")
    case .httpError(let statusCode, let message):
      return TTSError.synthesisFailure("HTTP \(statusCode): \(message)")
    }
  }

  /// Gemini returns headerless PCM by default, which the shared transport
  /// wraps in a RIFF header, so parts are always saved as WAV.
  private func saveAudioData(_ data: Data) throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
    let filename = "tts_\(UUID().uuidString).\(AudioFormat.wav.fileExtension)"
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
