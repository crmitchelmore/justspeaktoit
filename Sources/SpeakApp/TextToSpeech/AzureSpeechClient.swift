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

    // The shared transport keeps the subscription key inside the regional
    // Azure origin on any redirect.
    let data: Data
    do {
      data = try await AzureSpeechVoiceAPI(session: session).synthesize(
        credentials: credentials, text: text, voice: voice, format: outputFormat(for: settings),
        speed: settings.speed, pitch: settings.pitch, useSSML: settings.useSSML
      )
    } catch AzureSpeechError.service(let status) where status == 400 && AzureMAIVoiceCatalog.isMAIVoice(voice) {
      throw TTSError.synthesisFailure(
        "Azure rejected this MAI voice (HTTP 400). Check that your Speech resource can use MAI voices."
      )
    }

    // Save audio data to temporary file
    let outputURL = try await saveAudioData(data, format: settings.format == .m4a ? .mp3 : settings.format)

    // Calculate duration
    let duration = try await getAudioDuration(url: outputURL)

    // One pricing path: MAI voices are priced per model, neural voices at
    // ~$16 per 1M characters.
    let cost = provider.estimatedCost(characterCount: text.count, quality: settings.quality, voiceID: voice)

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
    let listed = voices.map { voice in
      TTSVoice(id: voice.id, name: voice.name, provider: .azure,
               traits: voice.gender == "Female" ? [.female] : [.male], previewURL: nil)
    }
    // Microsoft routes MAI-Voice-2.1 and Flash globally, so a regional listing
    // that omits them does not mean the resource cannot use them.
    let missing = AzureMAIVoiceCatalog.voicesMissing(fromListedIDs: Set(listed.map(\.id)))
    return listed + missing.map(VoiceCatalog.azureMAIVoice)
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
