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
    return .success(message: "System voice requires no API key")
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

/// Writes one utterance's buffers to an audio file and reports completion.
///
/// Finishes on the synthesizer's empty end buffer, falling back to its finish
/// callback; cancellation stops synthesis. The writer keeps itself, and so the
/// synthesizer, alive until the synthesizer reports it has stopped: freeing an
/// AVSpeechSynthesizer that is still delivering callbacks crashes the process.
private final class SystemSpeechFileWriter: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
  private let url: URL
  private let format: AudioFormat
  private let synthesizer = AVSpeechSynthesizer()
  private let lock = NSLock()
  private var file: AVAudioFile?
  private var continuation: CheckedContinuation<Void, Error>?
  private var outcome: Result<Void, Error>?
  private var keepAlive: SystemSpeechFileWriter?
  /// Bounds the self-retain if the synthesizer never reports that it stopped.
  private static let stopGrace: TimeInterval = 30

  init(url: URL, format: AudioFormat) {
    self.url = url
    self.format = format
    super.init()
    synthesizer.delegate = self
  }

  func write(_ utterance: AVSpeechUtterance) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let settled = lock.withLock { () -> Result<Void, Error>? in
          if let outcome { return outcome }
          self.continuation = continuation
          return nil
        }
        if let settled { continuation.resume(with: settled); return }
        lock.withLock { keepAlive = self }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopGrace) { [weak self] in self?.releaseSynthesizer() }
        synthesizer.write(utterance) { [weak self] buffer in self?.append(buffer) }
      }
    } onCancel: {
      self.finish(.failure(CancellationError()))
      self.synthesizer.stopSpeaking(at: .immediate)
    }
  }

  private func append(_ buffer: AVAudioBuffer) {
    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
    guard pcm.frameLength > 0 else { finish(.success(())); return }
    do {
      try lock.withLock {
        guard outcome == nil else { return }
        if file == nil {
          file = try AVAudioFile(
            forWriting: url, settings: Self.settings(for: format, matching: pcm.format),
            commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved
          )
        }
        try file?.write(from: pcm)
      }
    } catch {
      finish(.failure(TTSError.synthesisFailure("Could not write system speech: \(error.localizedDescription)")))
      synthesizer.stopSpeaking(at: .immediate)
    }
  }

  private func finish(_ result: Result<Void, Error>) {
    let settled = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Result<Void, Error>)? in
      guard outcome == nil else { return nil }
      var result = result
      if case .success = result, file == nil {
        result = .failure(TTSError.synthesisFailure("The system voice produced no audio"))
      }
      outcome = result
      file = nil  // Releasing the file closes it before anyone reads it.
      defer { continuation = nil }
      return (continuation, result)
    }
    if let (continuation, result) = settled { continuation?.resume(with: result) }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    // The empty end buffer normally finishes first; this is the fallback, after
    // a grace period so a trailing buffer is not cut off.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.finish(.success(()))
      self?.releaseSynthesizer()
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    finish(.failure(CancellationError()))
    releaseSynthesizer()
  }

  /// Drops the self-retain on the main queue, so the synthesizer is freed
  /// there and never from inside one of its own callbacks.
  private func releaseSynthesizer() {
    let retained = lock.withLock { () -> SystemSpeechFileWriter? in
      defer { keepAlive = nil }
      return keepAlive
    }
    guard let retained else { return }
    DispatchQueue.main.async { _ = retained }
  }

  private static func settings(for format: AudioFormat, matching pcm: AVAudioFormat) -> [String: Any] {
    var settings: [String: Any] = [
      AVSampleRateKey: pcm.sampleRate, AVNumberOfChannelsKey: pcm.channelCount
    ]
    switch format {
    case .wav:
      settings[AVFormatIDKey] = kAudioFormatLinearPCM
      settings[AVLinearPCMBitDepthKey] = 16
      settings[AVLinearPCMIsFloatKey] = false
      settings[AVLinearPCMIsBigEndianKey] = false
    case .m4a, .mp3:
      settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
    }
    return settings
  }
}
