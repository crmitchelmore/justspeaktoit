import AVFoundation
import Foundation

/// Joins the audio parts of a multi-request synthesis into one file.
///
/// A provider that caps the text of a single request makes the client speak a
/// long document in parts. The rest of the app expects one playable file per
/// result, so the parts are joined here and the intermediates are removed.
enum TTSAudioJoiner {
  /// Returns a single file holding `partURLs` in order.
  ///
  /// A lone part is returned unchanged, so the common short-text path does no
  /// extra work. The parts are removed once the joined file exists.
  static func join(_ partURLs: [URL], format: AudioFormat) throws -> URL {
    guard let first = partURLs.first else {
      throw TTSError.synthesisFailure("No audio was generated")
    }
    guard partURLs.count > 1 else { return first }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("tts_\(UUID().uuidString).\(format.fileExtension)")

    do {
      switch format {
      case .mp3:
        // MP3 is a stream of self-contained frames, so the bytes of the parts
        // append directly.
        try joinFrames(partURLs, to: outputURL)
      case .wav, .m4a:
        // These containers carry one header that describes the whole payload,
        // so the samples are decoded and written again.
        try joinSamples(partURLs, to: outputURL)
      }
    } catch {
      discard(partURLs + [outputURL])
      if let ttsError = error as? TTSError { throw ttsError }
      throw TTSError.synthesisFailure("Failed to join audio: \(error.localizedDescription)")
    }

    discard(partURLs)
    return outputURL
  }

  /// Removes temporary parts that are no longer needed.
  static func discard(_ partURLs: [URL]) {
    for url in partURLs {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private static func joinFrames(_ partURLs: [URL], to outputURL: URL) throws {
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
      throw TTSError.synthesisFailure("Failed to create the joined audio file")
    }
    let handle = try FileHandle(forWritingTo: outputURL)
    defer { try? handle.close() }
    for url in partURLs {
      try handle.write(contentsOf: Data(contentsOf: url))
    }
  }

  private static func joinSamples(_ partURLs: [URL], to outputURL: URL) throws {
    // Every part comes from the same request settings, so they share a sample
    // rate and a channel count and the first part describes the output.
    let template = try AVAudioFile(forReading: partURLs[0])
    let output = try AVAudioFile(forWriting: outputURL, settings: template.fileFormat.settings)

    for url in partURLs {
      let part = try AVAudioFile(forReading: url)
      guard part.length > 0,
        let buffer = AVAudioPCMBuffer(
          pcmFormat: part.processingFormat,
          frameCapacity: AVAudioFrameCount(part.length)
        )
      else { continue }
      try part.read(into: buffer)
      try output.write(from: buffer)
    }
  }
}
