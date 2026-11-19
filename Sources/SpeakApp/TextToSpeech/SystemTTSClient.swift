import SpeakCore
import Foundation
import AVFoundation

actor SystemTTSClient: TextToSpeechClient {
  let provider: TTSProvider = .system

  func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
    let voiceID = voice.replacingOccurrences(of: "system/", with: "")

    // "default" (and an empty identifier) is the system voice for the user's language.
    let systemVoice = voiceID.isEmpty || voiceID == "default"
      ? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
      : AVSpeechSynthesisVoice.speechVoices().first { voice in
        voice.identifier.contains(voiceID) || voice.name.lowercased().contains(voiceID.lowercased())
      } ?? AVSpeechSynthesisVoice(language: "en-US")

    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = systemVoice
    utterance.rate = Float(settings.speed * 0.5)  // AVSpeech uses 0-1 range
    utterance.pitchMultiplier = Float(1.0 + (settings.pitch / 20.0))  // Adjust pitch

    // Use AVSpeechSynthesizer to write to file
    let outputURL = try await synthesizeToFile(utterance: utterance, format: settings.format)

    // Calculate duration
    let duration = try await getAudioDuration(url: outputURL)

    return TTSResult(
      audioURL: outputURL,
      provider: provider,
      voice: voice,
      duration: duration,
      characterCount: text.count,
      cost: nil  // System voice is free
    )
  }

  func listVoices() async throws -> [TTSVoice] {
    let systemVoices = AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.hasPrefix("en") }
      .map { voice in
        let traits = detectTraits(from: voice)
        return TTSVoice(
          id: "system/\(voice.identifier)",
          name: voice.name,
          provider: .system,
          traits: traits,
          previewURL: nil
        )
      }

    return systemVoices.isEmpty ? VoiceCatalog.systemVoices : systemVoices
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    // System voice doesn't require API key
    .success(message: "System voice requires no API key")
  }

  // MARK: - Private Helpers

  /// Renders the utterance with AVSpeechSynthesizer and returns the file once
  /// the last buffer is written. AVFoundation has no MP3 encoder, so an MP3
  /// request is written as AAC (`.m4a`) and named for what it contains.
  private func synthesizeToFile(utterance: AVSpeechUtterance, format: AudioFormat) async throws -> URL {
    let fileFormat: AudioFormat = format == .mp3 ? .m4a : format
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("tts_\(UUID().uuidString).\(fileFormat.fileExtension)")
    let writer = SystemSpeechFileWriter(url: fileURL, format: fileFormat)
    do {
      try await writer.write(utterance)
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
      throw error
    }
    return fileURL
  }

  private func getAudioDuration(url: URL) async throws -> TimeInterval {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    return CMTimeGetSeconds(duration)
  }

  private func detectTraits(from voice: AVSpeechSynthesisVoice) -> [TTSVoice.VoiceTrait] {
    var traits: [TTSVoice.VoiceTrait] = [.builtin]

    let nameLower = voice.name.lowercased()
    let identifier = voice.identifier.lowercased()

    // Detect gender
    let femaleNames = ["samantha", "victoria", "karen", "moira", "fiona", "tessa", "serena"]
    let maleNames = ["alex", "daniel", "tom", "fred", "ralph", "oliver"]

    if femaleNames.contains(where: { nameLower.contains($0) || identifier.contains($0) }) {
      traits.append(.female)
    } else if maleNames.contains(where: { nameLower.contains($0) || identifier.contains($0) }) {
      traits.append(.male)
    }

    // Detect accent/locale
    if voice.language.hasPrefix("en-US") {
      traits.append(.american)
    } else if voice.language.hasPrefix("en-GB") {
      traits.append(.british)
    } else if voice.language.hasPrefix("en-AU") {
      traits.append(.australian)
    }

    return traits
  }
}
