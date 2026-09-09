import SpeakCore
import AVFoundation
import Foundation

/// Groq Orpheus TTS client.
///
/// HTTP transport lives in `SpeakCore.GroqTTSAPI` and the model and voice lists
/// in `SpeakCore.GroqTTSCatalog`; this wrapper adds keychain lookup, request
/// chunking, file handling and cost tracking. One Groq key covers Whisper
/// transcription and Orpheus speech generation.
///
/// A stored key is not evidence of access: Orpheus is gated behind a
/// per-organisation model-terms acceptance in the Groq console, which only
/// surfaces on the first synthesis request. That failure is reported with the
/// console link rather than as a bad key.
actor GroqTTSClient: TextToSpeechClient {
  let provider: TTSProvider = .groq
  private let api: GroqTTSAPI
  private let secureStorage: SecureAppStorage

  init(secureStorage: SecureAppStorage, session: URLSession = .shared) {
    self.secureStorage = secureStorage
    self.api = GroqTTSAPI(session: session)
  }

  func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
    // Groq caps one Orpheus request at 200 characters. Longer input becomes a
    // sequence of requests split at sentence ends, and the parts are joined
    // into the single file the caller expects.
    let segments = TTSTextChunker.chunks(
      text,
      maximumCharacters: GroqTTSAPI.maxInputCharacters
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

    let request = GroqTTSRequest(voiceID: voice)
    let resolved = GroqTTSCatalog.resolvedVoice(forID: voice)

    var partURLs: [URL] = []
    var duration: TimeInterval = 0
    do {
      for segment in segments {
        let data = try await api.synthesize(input: segment, apiKey: apiKey, request: request)
        let partURL = try saveAudioData(data)
        partURLs.append(partURL)
        duration += try await getAudioDuration(url: partURL)
      }
    } catch let error as GroqTTSAPIError {
      TTSAudioJoiner.discard(partURLs)
      throw Self.ttsError(for: error)
    } catch {
      TTSAudioJoiner.discard(partURLs)
      throw error
    }

    let outputURL = try TTSAudioJoiner.join(partURLs, format: .wav)
    let cost = Decimal(text.count) * resolved.model.costPerThousandCharacters / 1000

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
    // Groq publishes no voice-listing endpoint; the documented personas are the
    // whole list.
    VoiceCatalog.groqVoices
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    await api.validateAPIKey(key)
  }

  // MARK: - Private Helpers

  /// Orpheus accepts the model, the text and the voice. Groq's generic speech
  /// reference still lists `speed` and `sample_rate`, but those belong to the
  /// retired PlayAI models, so the app reports them as ignored rather than
  /// pretending they applied.
  static func unsupportedSettingsMessage(_ settings: TTSSettings) -> String? {
    var ignored: [String] = []
    if abs(settings.speed - 1.0) > 0.001 { ignored.append("speed") }
    if abs(settings.pitch) > 0.001 { ignored.append("pitch") }
    guard !ignored.isEmpty else { return nil }
    return "Groq Orpheus voices do not support \(ignored.joined(separator: " or ")) control. "
      + "Reset it to the default, or choose another provider."
  }

  static func ttsError(for error: GroqTTSAPIError) -> TTSError {
    switch error {
    case .invalidResponse:
      return TTSError.synthesisFailure("Invalid response")
    case .emptyText:
      return TTSError.synthesisFailure("There is no text to speak")
    case .unauthorized:
      // The status code is the deciding signal: a revoked key must point the
      // user at Settings rather than at a generic synthesis failure.
      return TTSError.apiKeyMissing(.groq)
    case .modelTermsRequired(let message):
      return TTSError.providerAccessRequired(
        .groq,
        reason: "\(message) Accept the model terms at \(GroqTTSAPI.modelTermsURL)."
      )
    case .accessBlocked(let message):
      return TTSError.providerAccessRequired(.groq, reason: message)
    case .rateLimited(let message):
      return TTSError.synthesisFailure("Groq rate limit reached: \(message)")
    case .httpError(let statusCode, let message):
      return TTSError.synthesisFailure("HTTP \(statusCode): \(message)")
    }
  }

  /// Orpheus returns WAV only, so the audio-format preference has nothing to
  /// choose and the file is named for what it actually holds.
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
