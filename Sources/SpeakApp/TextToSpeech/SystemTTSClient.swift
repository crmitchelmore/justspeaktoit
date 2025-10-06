import Foundation
import AVFoundation
import AppKit

actor SystemTTSClient: TextToSpeechClient {
  let provider: TTSProvider = .system

  func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
    let voiceID = voice.replacingOccurrences(of: "system/", with: "")

    // Find the system voice
    let systemVoice = AVSpeechSynthesisVoice.speechVoices().first { voice in
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
    return .success(message: "System voice requires no API key")
  }

  // MARK: - Private Helpers

  private func synthesizeToFile(utterance: AVSpeechUtterance, format: AudioFormat) async throws
    -> URL
  {
    // For macOS system TTS, we'll use a simplified approach
    // We'll synthesize to a temporary file and return it
    let tempDir = FileManager.default.temporaryDirectory
    let filename = "tts_\(UUID().uuidString).\(format.fileExtension)"
    let fileURL = tempDir.appendingPathComponent(filename)

    // Use NSSpeechSynthesizer for macOS
    return try await withCheckedThrowingContinuation { continuation in
      let voiceIdentifier = utterance.voice?.identifier
      let voiceName = voiceIdentifier.map { NSSpeechSynthesizer.VoiceName(rawValue: $0) }
      let synthesizer = NSSpeechSynthesizer(voice: voiceName)

      // Start writing to URL
      if synthesizer?.startSpeaking(utterance.speechString, to: fileURL) == true {
        // Wait for completion - this is a simple timeout approach
        DispatchQueue.global().asyncAfter(
          deadline: .now() + Double(utterance.speechString.count) / 15.0 + 1.0
        ) {
          continuation.resume(returning: fileURL)
        }
      } else {
        continuation.resume(throwing: TTSError.synthesisFailure("Failed to start synthesis"))
      }
    }
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
