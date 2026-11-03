import SpeakCore
import Foundation
import AVFoundation

actor OpenAITTSClient: TextToSpeechClient {
  let provider: TTSProvider = .openai
  private let baseURL = URL(string: "https://api.openai.com/v1")!
  private let session: URLSession
  private let secureStorage: SecureAppStorage

  init(secureStorage: SecureAppStorage, session: URLSession = .shared) {
    self.secureStorage = secureStorage
    self.session = session
  }

  func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
    if let realtimeVoice = OpenAIRealtimeSpeech.voiceID(fromProviderVoiceID: voice) {
      return try await synthesizeRealtime(text: text, voice: voice, realtimeVoice: realtimeVoice, settings: settings)
    }
    let selection = OpenAITTSRequest(
      model: try OpenAITTSCatalog.model(forQualityIdentifier: settings.quality.rawValue),
      voiceID: voice, speed: settings.speed, format: responseFormat(for: settings.format)
    )
    try OpenAITTSAPI.validate(text: text, request: selection)
    guard let apiKey = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
      !apiKey.isEmpty
    else {
      throw TTSError.apiKeyMissing(provider)
    }

    let request = try OpenAITTSAPI.synthesisRequest(text: text, apiKey: apiKey, request: selection)

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

    // Estimate cost based on model
    // gpt-4o-mini-tts: $0.60/1M, tts-1: $15/1M, tts-1-hd: $30/1M
    let pricePerMillion: Decimal
    switch settings.quality {
    case .standard: pricePerMillion = 0.60
    case .high: pricePerMillion = 15.0
    case .highest: pricePerMillion = 30.0
    }
    let cost = Decimal(text.count) * pricePerMillion / 1_000_000.0

    return TTSResult(
      audioURL: outputURL,
      provider: provider,
      voice: voice,
      duration: duration,
      characterCount: text.count,
      cost: cost
    )
  }

  /// Opt-in voices on the Realtime API. Always WAV: the socket returns PCM.
  private func synthesizeRealtime(
    text: String, voice: String, realtimeVoice: String, settings: TTSSettings
  ) async throws -> TTSResult {
    guard let apiKey = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
      !apiKey.isEmpty
    else {
      throw TTSError.apiKeyMissing(provider)
    }
    let result: OpenAIRealtimeSpeechSynthesizer.Result
    do {
      result = try await OpenAIRealtimeSpeechSynthesizer(session: session)
        .synthesize(text: text, voice: realtimeVoice, speed: settings.speed, apiKey: apiKey)
    } catch let error as OpenAIRealtimeSpeechError {
      throw TTSError.synthesisFailure(error.localizedDescription)
    }
    guard let wav = PCMWaveWriter.wavData(pcm: result.pcm, sampleRate: OpenAIRealtimeSpeech.sampleRate) else {
      throw TTSError.synthesisFailure("OpenAI returned audio Speak could not write as WAV")
    }
    let outputURL = try await saveAudioData(wav, format: .wav)
    return TTSResult(
      audioURL: outputURL,
      provider: provider,
      voice: voice,
      duration: try await getAudioDuration(url: outputURL),
      characterCount: text.count,
      cost: result.usage.cost
    )
  }

  func listVoices() async throws -> [TTSVoice] {
    VoiceCatalog.openaiVoices
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let url = baseURL.appendingPathComponent("models")
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

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

  private func responseFormat(for format: AudioFormat) -> OpenAITTSOutputFormat {
    switch format {
    case .mp3: return .mp3
    case .m4a: return .aac
    case .wav: return .wav
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
