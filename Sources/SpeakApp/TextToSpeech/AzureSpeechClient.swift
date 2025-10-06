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

    let (apiKey, region) = parseCredentials(credentials)
    let voiceID = voice.replacingOccurrences(of: "azure/", with: "")

    let baseURL = URL(string: "https://\(region).tts.speech.microsoft.com")!
    let url = baseURL.appendingPathComponent("cognitiveservices/v1")

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
    request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
    request.setValue(outputFormat(for: settings), forHTTPHeaderField: "X-Microsoft-OutputFormat")
    request.setValue("speak-app", forHTTPHeaderField: "User-Agent")

    // Build SSML
    let ssml: String
    if settings.useSSML && text.contains("<speak>") {
      ssml = text
    } else if settings.useSSML {
      // Wrap in speak tags if SSML is enabled but not present
      ssml = buildSSML(text: text, voice: voiceID, settings: settings)
    } else {
      ssml = buildSSML(text: text, voice: voiceID, settings: settings)
    }

    request.httpBody = ssml.data(using: .utf8)

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw TTSError.synthesisFailure("Invalid response")
    }

    if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
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

    // Estimate cost (Azure pricing: ~$16 per 1M characters for neural voices)
    let cost = Decimal(text.count) * 16.0 / 1_000_000.0

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
    return VoiceCatalog.azureVoices
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let (apiKey, region) = parseCredentials(key)

    guard !region.isEmpty else {
      return .failure(
        message:
          "Azure requires both API key and region. Format: 'your-api-key:your-region' (e.g., 'abc123:eastus')"
      )
    }

    let baseURL = URL(string: "https://\(region).tts.speech.microsoft.com")!
    let url = baseURL.appendingPathComponent("cognitiveservices/voices/list")

    var request = URLRequest(url: url)
    request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")

    do {
      let (_, response) = try await session.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        return .failure(message: "Invalid response")
      }

      if httpResponse.statusCode == 200 {
        return .success(message: "API key and region are valid")
      } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
        return .failure(message: "Invalid API key or region")
      } else {
        return .failure(message: "HTTP \(httpResponse.statusCode)")
      }
    } catch {
      return .failure(message: error.localizedDescription)
    }
  }

  // MARK: - Private Helpers

  private func parseCredentials(_ credentials: String) -> (apiKey: String, region: String) {
    let parts = credentials.split(separator: ":", maxSplits: 1)
    if parts.count == 2 {
      return (String(parts[0]), String(parts[1]))
    }
    // Default to eastus if no region specified
    return (credentials, "eastus")
  }

  private func buildSSML(text: String, voice: String, settings: TTSSettings) -> String {
    let rate = rateAttribute(for: settings.speed)
    let pitch = pitchAttribute(for: settings.pitch)

    return """
      <speak version='1.0' xml:lang='en-US'>
        <voice name='\(voice)'>
          <prosody rate='\(rate)' pitch='\(pitch)'>
            \(text)
          </prosody>
        </voice>
      </speak>
      """
  }

  private func rateAttribute(for speed: Double) -> String {
    let percentage = Int((speed - 1.0) * 100)
    if percentage > 0 {
      return "+\(percentage)%"
    } else if percentage < 0 {
      return "\(percentage)%"
    }
    return "0%"
  }

  private func pitchAttribute(for pitch: Double) -> String {
    if pitch > 0 {
      return "+\(Int(pitch))st"
    } else if pitch < 0 {
      return "\(Int(pitch))st"
    }
    return "0st"
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
