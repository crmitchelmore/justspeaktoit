import SpeakCore
import Foundation
import AVFoundation

actor AzureSpeechClient: TextToSpeechClient {
  let provider: TTSProvider = .azure
  private let session: URLSession
  private let secureStorage: SecureAppStorage
  private let appSettings: AppSettings

  // Azure requires both API key and region
  // We'll store region in the API key as "key:region" format
  init(secureStorage: SecureAppStorage, appSettings: AppSettings, session: URLSession = .shared) {
    self.secureStorage = secureStorage
    self.appSettings = appSettings
    self.session = session
  }

  func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
    guard let credentials = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
      !credentials.isEmpty
    else {
      throw TTSError.apiKeyMissing(provider)
    }

    let request = try AzureSpeechVoiceAPI.synthesisRequest(
      credentials: credentials, text: text, voice: voice, format: outputFormat(for: settings),
      speed: settings.speed, pitch: settings.pitch, useSSML: settings.useSSML
    )

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw TTSError.synthesisFailure("Invalid response")
    }

    if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
      throw AzureSpeechError.service(httpResponse.statusCode)
    }

    guard httpResponse.statusCode == 200 else {
      let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
      throw TTSError.synthesisFailure("HTTP \(httpResponse.statusCode): \(errorMessage)")
    }

    // Save audio data to temporary file
    let outputURL = try await saveAudioData(data, format: settings.format == .m4a ? .mp3 : settings.format)

    // Calculate duration
    let duration = try await getAudioDuration(url: outputURL)

    // Estimate cost (Azure pricing: ~$16 per 1M characters for neural voices)
    let cost: Decimal? = voice.contains(":MAI-Voice-") ? nil : Decimal(text.count) * 16.0 / 1_000_000.0

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
    guard let key = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier), !key.isEmpty else {
      return VoiceCatalog.azureVoices
    }
    guard let voices = try? await AzureSpeechVoiceAPI(session: session).listVoices(credentials: key),
          !voices.isEmpty else {
      return VoiceCatalog.azureVoices
    }
    return voices.map { voice in
      TTSVoice(id: voice.id, name: voice.name, provider: .azure,
               traits: voice.gender == "Female" ? [.female] : [.male], previewURL: nil)
    }
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    do {
      _ = try await AzureSpeechVoiceAPI(session: session).listVoices(credentials: key)
      return .success(message: "Azure key and region are valid. Model access depends on your resource.")
    } catch {
      return .failure(message: error.localizedDescription)
    }
  }

  private func outputFormat(for settings: TTSSettings) -> String {
    // Azure format: audio-quality-samplerate-codec-bitrate
    switch settings.format {
    case .mp3:
      return settings.quality == .highest
        ? "audio-48khz-192kbitrate-mono-mp3" : "audio-24khz-96kbitrate-mono-mp3"
    case .m4a:
      return "audio-24khz-48kbitrate-mono-mp3"  // Azure doesn't support AAC directly
    case .wav:
      return settings.quality == .highest ? "riff-48khz-16bit-mono-pcm" : "riff-24khz-16bit-mono-pcm"
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
