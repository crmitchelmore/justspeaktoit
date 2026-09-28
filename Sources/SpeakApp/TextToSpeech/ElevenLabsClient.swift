import SpeakCore
import Foundation
import AVFoundation

/// Current ElevenLabs text-to-speech models, plus the deprecated identifiers
/// they replace. ElevenLabs deprecated `eleven_turbo_v2_5` in favour of
/// `eleven_flash_v2_5`. `eleven_v4` is now the most expressive model, but
/// ElevenLabs only serves it through the Text to Dialogue API, so it has its
/// own request path and `eleven_v3` stays as its text-to-speech fallback.
enum ElevenLabsTTSModels {
  struct Model: Equatable {
    let id: String
    let displayName: String
  }

  static let elevenV4 = Model(id: "eleven_v4", displayName: "Eleven v4 (most expressive)")
  static let elevenV3 = Model(id: "eleven_v3", displayName: "Eleven v3")
  static let multilingualV2 = Model(id: "eleven_multilingual_v2", displayName: "Eleven Multilingual v2")
  static let flashV25 = Model(id: "eleven_flash_v2_5", displayName: "Eleven Flash v2.5 (fastest)")

  static let all: [Model] = [elevenV4, elevenV3, multilingualV2, flashV25]

  /// Models ElevenLabs serves only through `POST /v1/text-to-dialogue`.
  static let dialogueOnlyModelIDs: Set<String> = [elevenV4.id]

  /// ElevenLabs' guidance for reliable Text to Dialogue generation is at most
  /// 2,000 characters across all inputs; longer text goes to the fallback.
  static let dialogueCharacterLimit = 2_000

  /// Text-to-speech model used when a dialogue-only model cannot take the request.
  static let dialogueFallback = elevenV3

  /// Deprecated identifiers mapped onto the model ElevenLabs recommends instead.
  static let deprecatedReplacements: [String: String] = [
    "eleven_turbo_v2_5": flashV25.id,
    "eleven_turbo_v2": flashV25.id,
    "eleven_multilingual_v1": multilingualV2.id
  ]

  /// Maps a persisted or caller-supplied identifier onto a model ElevenLabs
  /// still serves. Unknown identifiers pass through so custom models keep working.
  static func current(_ identifier: String) -> String {
    let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    return deprecatedReplacements[trimmed] ?? trimmed
  }
}

actor ElevenLabsClient: TextToSpeechClient {
  let provider: TTSProvider = .elevenlabs
  private let baseURL = URL(string: "https://api.elevenlabs.io/v1")!
  private let session: URLSession
  private let secureStorage: SecureAppStorage

  init(secureStorage: SecureAppStorage, session: URLSession = .shared) {
    self.secureStorage = secureStorage
    self.session = session
  }

  func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
    guard let apiKey = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
      !apiKey.isEmpty
    else {
      throw TTSError.apiKeyMissing(provider)
    }

    let data = try await audioData(text: text, voice: voice, quality: settings.quality, apiKey: apiKey)

    // Save audio data to temporary file
    let outputURL = try await saveAudioData(data, format: settings.format)

    // Calculate duration
    let duration = try await getAudioDuration(url: outputURL)

    // Estimate cost (ElevenLabs pricing: ~$0.30 per 1000 characters for standard)
    let cost = Decimal(text.count) * 0.30 / 1000.0

    return TTSResult(
      audioURL: outputURL,
      provider: provider,
      voice: voice,
      duration: duration,
      characterCount: text.count,
      cost: cost
    )
  }

  func listVoices() async throws -> [TTSVoice] {
    guard let apiKey = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
      !apiKey.isEmpty
    else {
      return VoiceCatalog.elevenlabsVoices
    }

    let url = baseURL.appendingPathComponent("voices")
    var request = URLRequest(url: url)
    request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

    do {
      let (data, _) = try await session.data(for: request)
      let response = try JSONDecoder().decode(VoicesResponse.self, from: data)

      return response.voices.map { voice in
        TTSVoice(
          id: "elevenlabs/\(voice.voice_id)",
          name: voice.name,
          provider: .elevenlabs,
          traits: detectTraits(from: voice.labels),
          previewURL: voice.preview_url
        )
      }
    } catch {
      return VoiceCatalog.elevenlabsVoices
    }
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    await ElevenLabsSTTAPIKeyValidator(session: session).validate(key)
  }

  /// Requests synthesized audio for `quality`, routing dialogue-only models
  /// through Text to Dialogue. Split from `synthesize` so the request routing
  /// can be exercised without a keychain-stored key.
  func audioData(text: String, voice: String, quality: TTSQuality, apiKey: String) async throws -> Data {
    let voiceID = voice.replacingOccurrences(of: "elevenlabs/", with: "")
    let resolvedModelID = ElevenLabsTTSModels.current(modelID(for: quality))
    if ElevenLabsTTSModels.dialogueOnlyModelIDs.contains(resolvedModelID) {
      return try await synthesizeDialogueFirst(
        text: text, voiceID: voiceID, modelID: resolvedModelID, apiKey: apiKey)
    }
    return try await synthesizeSpeech(text: text, voiceID: voiceID, modelID: resolvedModelID, apiKey: apiKey)
  }

  // MARK: - Private Helpers

  /// Sends a dialogue-only model through Text to Dialogue as a single turn.
  /// Text over the reliable dialogue length, or a request ElevenLabs rejects
  /// (for example an account without v4 access), falls back to the
  /// text-to-speech model so reading aloud keeps working.
  private func synthesizeDialogueFirst(
    text: String, voiceID: String, modelID: String, apiKey: String
  ) async throws -> Data {
    let fallbackID = ElevenLabsTTSModels.dialogueFallback.id
    guard text.count <= ElevenLabsTTSModels.dialogueCharacterLimit else {
      return try await synthesizeSpeech(text: text, voiceID: voiceID, modelID: fallbackID, apiKey: apiKey)
    }
    do {
      return try await synthesizeDialogue(text: text, voiceID: voiceID, modelID: modelID, apiKey: apiKey)
    } catch ElevenLabsRequestError.rejected {
      return try await synthesizeSpeech(text: text, voiceID: voiceID, modelID: fallbackID, apiKey: apiKey)
    }
  }

  private func synthesizeSpeech(
    text: String, voiceID: String, modelID: String, apiKey: String
  ) async throws -> Data {
    let url = baseURL.appendingPathComponent("text-to-speech").appendingPathComponent(voiceID)
    let body: [String: Any] = [
      "text": text,
      "model_id": modelID,
      "voice_settings": [
        "stability": 0.5,
        "similarity_boost": 0.75,
        "style": 0.0,
        "use_speaker_boost": true,
      ],
    ]
    return try await send(body: body, to: url, apiKey: apiKey, fallbackOnRejection: false)
  }

  private func synthesizeDialogue(
    text: String, voiceID: String, modelID: String, apiKey: String
  ) async throws -> Data {
    let url = baseURL.appendingPathComponent("text-to-dialogue")
    let body: [String: Any] = [
      "inputs": [["text": text, "voice_id": voiceID]],
      "model_id": modelID,
    ]
    return try await send(body: body, to: url, apiKey: apiKey, fallbackOnRejection: true)
  }

  private enum ElevenLabsRequestError: Error {
    case rejected
  }

  private func send(
    body: [String: Any], to url: URL, apiKey: String, fallbackOnRejection: Bool
  ) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw TTSError.synthesisFailure("Invalid response")
    }

    if httpResponse.statusCode == 401 {
      throw TTSError.apiKeyMissing(provider)
    }

    // 400/403/404/422 mean the model or endpoint refused this request; rate
    // limits and server errors surface unchanged rather than switching models.
    if fallbackOnRejection, [400, 403, 404, 422].contains(httpResponse.statusCode) {
      throw ElevenLabsRequestError.rejected
    }

    guard httpResponse.statusCode == 200 else {
      let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
      throw TTSError.synthesisFailure("HTTP \(httpResponse.statusCode): \(errorMessage)")
    }
    return data
  }

  private func modelID(for quality: TTSQuality) -> String {
    switch quality {
    case .standard:
      // Flash v2.5 - fastest, ~75ms latency, great for real-time
      return ElevenLabsTTSModels.flashV25.id
    case .high:
      // Multilingual v2 - best quality for most use cases
      return ElevenLabsTTSModels.multilingualV2.id
    case .highest:
      // Eleven v4 - most expressive, best for narration and emotive speech
      return ElevenLabsTTSModels.elevenV4.id
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

  private func detectTraits(from labels: [String: String]?) -> [TTSVoice.VoiceTrait] {
    guard let labels else { return [] }

    var traits: [TTSVoice.VoiceTrait] = []

    if let gender = labels["gender"]?.lowercased() {
      if gender.contains("male") && !gender.contains("female") {
        traits.append(.male)
      } else if gender.contains("female") {
        traits.append(.female)
      }
    }

    if let accent = labels["accent"]?.lowercased() {
      if accent.contains("american") {
        traits.append(.american)
      } else if accent.contains("british") {
        traits.append(.british)
      }
    }

    if let useCase = labels["use case"]?.lowercased() {
      if useCase.contains("professional") {
        traits.append(.professional)
      }
    }

    return traits
  }

  // MARK: - Response Models

  private struct VoicesResponse: Codable {
    let voices: [Voice]
  }

  private struct Voice: Codable {
    let voice_id: String
    let name: String
    let preview_url: URL?
    let labels: [String: String]?
  }
}
