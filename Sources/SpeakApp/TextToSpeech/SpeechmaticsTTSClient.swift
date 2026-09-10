import SpeakCore
import AVFoundation
import Foundation

/// Speechmatics text-to-speech client.
///
/// HTTP transport lives in `SpeakCore.SpeechmaticsTTSAPI` and the voice list in
/// `SpeakCore.SpeechmaticsTTSCatalog`; this wrapper adds keychain lookup, file
/// handling and cost tracking. One portal key covers transcription and speech
/// generation, so a user who already dictates with Speechmatics gets voices with
/// no extra setup.
///
/// Speechmatics documents no speaking-rate, pitch, sample-rate or language
/// parameter, so those settings are reported as unsupported rather than
/// silently dropped.
actor SpeechmaticsTTSClient: TextToSpeechClient {
  let provider: TTSProvider = .speechmatics
  private let api: SpeechmaticsTTSAPI
  private let secureStorage: SecureAppStorage

  init(secureStorage: SecureAppStorage, session: URLSession = .shared) {
    self.secureStorage = secureStorage
    self.api = SpeechmaticsTTSAPI(session: session)
  }

  func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

    let request = SpeechmaticsTTSRequest(voiceID: voice)
    let data: Data
    do {
      data = try await api.synthesize(text: text, apiKey: apiKey, request: request)
    } catch let error as SpeechmaticsTTSAPIError {
      throw Self.ttsError(for: error)
    }

    let outputURL = try saveAudioData(data, format: .wav)
    // A 2xx body that is not decodable audio makes duration reading throw;
    // without this the UUID-named file would be left behind every time.
    let duration: TimeInterval
    do {
      duration = try await getAudioDuration(url: outputURL)
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }
    let cost =
      Decimal(text.count) * SpeechmaticsTTSAPI.estimatedCostPerThousandCharacters / 1000

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
    // Speechmatics publishes no voice-listing endpoint; the catalogue is the
    // whole list.
    VoiceCatalog.speechmaticsVoices
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    await api.validateAPIKey(key)
  }

  // MARK: - Private Helpers

  /// Speechmatics accepts only the text and the voice. Reporting the ignored
  /// controls is better than pretending they applied.
  static func unsupportedSettingsMessage(_ settings: TTSSettings) -> String? {
    var ignored: [String] = []
    if abs(settings.speed - 1.0) > 0.001 { ignored.append("speed") }
    if abs(settings.pitch) > 0.001 { ignored.append("pitch") }
    if !ignored.isEmpty {
      return "Speechmatics voices do not support \(ignored.joined(separator: " or ")) control. "
        + "Reset it to the default, or choose another provider."
    }
    // The four voices are English only and the request carries no language
    // parameter, so an explicit non-English choice would be dropped in silence.
    if let language = requestedNonEnglishLanguage(settings) {
      return "Speechmatics voices speak English only, so the \(language) output language "
        + "cannot be honoured. Set the voice-output language back to Automatic or English, "
        + "or choose another provider."
    }
    return nil
  }

  /// The chosen output language when it is an explicit non-English one.
  ///
  /// Automatic makes no claim, and Speechmatics happens to serve English, so
  /// only a deliberate other choice is a conflict.
  static func requestedNonEnglishLanguage(_ settings: TTSSettings) -> String? {
    let normalized = VoiceOutputLanguageCatalog.normalizedIdentifier(settings.language)
    guard normalized != VoiceOutputLanguageCatalog.automaticIdentifier else { return nil }
    let base = normalized
      .lowercased()
      .split(whereSeparator: { $0 == "_" || $0 == "-" })
      .first
      .map(String.init)
    guard let base, base != "en" else { return nil }
    return VoiceOutputLanguageCatalog.options
      .first { $0.id.caseInsensitiveCompare(normalized) == .orderedSame }?
      .displayName ?? normalized
  }

  static func ttsError(for error: SpeechmaticsTTSAPIError) -> TTSError {
    switch error {
    case .invalidResponse:
      return TTSError.synthesisFailure("Invalid response")
    case .emptyText:
      return TTSError.synthesisFailure("There is no text to speak")
    case .unauthorized:
      // The status code is the deciding signal: a revoked key must point the
      // user at Settings rather than at a generic synthesis failure.
      return TTSError.apiKeyMissing(.speechmatics)
    case .quotaExceeded(let message):
      return TTSError.synthesisFailure("Speechmatics credit exhausted: \(message)")
    case .rateLimited(let message):
      return TTSError.synthesisFailure("Speechmatics rate limit reached: \(message)")
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
