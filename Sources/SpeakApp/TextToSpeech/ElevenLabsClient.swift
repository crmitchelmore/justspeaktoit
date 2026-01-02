import Foundation
import AVFoundation

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

    let voiceID = voice.replacingOccurrences(of: "elevenlabs/", with: "")
    let url = baseURL.appendingPathComponent("text-to-speech").appendingPathComponent(voiceID)

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body: [String: Any] = [
      "text": text,
      "model_id": modelID(for: settings.quality),
      "voice_settings": [
        "stability": 0.5,
        "similarity_boost": 0.75,
        "style": 0.0,
        "use_speaker_boost": true,
      ],
    ]

    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw TTSError.synthesisFailure("Invalid response")
    }

    if httpResponse.statusCode == 401 {
      throw TTSError.apiKeyMissing(provider)
    }

    guard httpResponse.statusCode == 200 else {
      let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
      throw TTSError.synthesisFailure("HTTP \(httpResponse.statusCode): \(errorMessage)")
    }

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
    let url = baseURL.appendingPathComponent("user")
    var request = URLRequest(url: url)
    request.setValue(key, forHTTPHeaderField: "xi-api-key")

    do {
      let (_, response) = try await session.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        return .failure(message: "Invalid response")
      }

      if httpResponse.statusCode == 200 {
        return .success(message: "API key is valid")
      } else if httpResponse.statusCode == 401 {
        return .failure(message: "Invalid API key")
      } else {
        return .failure(message: "HTTP \(httpResponse.statusCode)")
      }
    } catch {
      return .failure(message: error.localizedDescription)
    }
  }

  // MARK: - Private Helpers

  private func modelID(for quality: TTSQuality) -> String {
    switch quality {
    case .standard:
      // Flash v2.5 - fastest, ~75ms latency, great for real-time
      return "eleven_flash_v2_5"
    case .high:
      // Multilingual v2 - best quality for most use cases
      return "eleven_multilingual_v2"
    case .highest:
      // Turbo v2.5 - balanced quality and speed
      return "eleven_turbo_v2_5"
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
