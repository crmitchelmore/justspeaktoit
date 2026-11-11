import AVFoundation
import Foundation
import SpeakCore

/// Writes one utterance's buffers to an audio file and reports completion.
///
/// Only the synthesizer's finish callback completes the file. `write(_:)` also
/// delivers empty buffers at some sentence boundaries inside an utterance and
/// then carries on with audio, so an empty buffer is never treated as the end:
/// doing so truncated multi-sentence `speak say` output while reporting success.
/// If the synthesizer goes quiet without finishing, the render fails rather than
/// returning partial audio; that bound runs from the last buffer, never from the
/// start, so long text is not cut off. Cancellation stops synthesis.
///
/// The writer keeps itself, and so the synthesizer, alive until the synthesizer
/// reports it has stopped: freeing an AVSpeechSynthesizer that is still
/// delivering callbacks crashes the process. The callbacks capture the writer
/// strongly, which the keep-alive makes safe, rather than forming a weak
/// reference to an object that may be freeing.
final class SystemSpeechFileWriter: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
  typealias Render = (AVSpeechSynthesizer, AVSpeechUtterance, @escaping (AVAudioBuffer) -> Void) -> Void

  private let url: URL
  private let format: AudioFormat
  private let synthesizer = AVSpeechSynthesizer()
  private let lock = NSLock()
  private var file: AVAudioFile?
  private var continuation: CheckedContinuation<Void, Error>?
  private var outcome: Result<Void, Error>?
  private var synthesisFinished = false
  private var lastProgress = DispatchTime.now()
  /// Lets a trailing buffer land after the finish callback.
  private let finishGrace: TimeInterval
  /// How long the synthesizer may go without a buffer before the render fails.
  private let stallTimeout: TimeInterval
  private let render: Render
  /// Bounds the self-retain, once the outcome is known, if the synthesizer
  /// never reports that it stopped.
  private let lifetime = SynthesizerKeepAlive<SystemSpeechFileWriter>(grace: 10)

  init(
    url: URL,
    format: AudioFormat,
    finishGrace: TimeInterval = 0.5,
    stallTimeout: TimeInterval = 30,
    render: @escaping Render = { synthesizer, utterance, onBuffer in
      synthesizer.write(utterance, toBufferCallback: onBuffer)
    }
  ) {
    self.url = url
    self.format = format
    self.finishGrace = finishGrace
    self.stallTimeout = stallTimeout
    self.render = render
    super.init()
    synthesizer.delegate = self
  }

  func write(_ utterance: AVSpeechUtterance) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let settled = lock.withLock { () -> Result<Void, Error>? in
          if let outcome { return outcome }
          self.continuation = continuation
          lastProgress = .now()
          // Retained before any outcome can settle, so the bound always starts.
          lifetime.retain(self)
          return nil
        }
        if let settled { continuation.resume(with: settled); return }
        render(synthesizer, utterance) { buffer in self.append(buffer) }
        watchForStall(after: stallTimeout)
      }
    } onCancel: {
      self.finish(.failure(CancellationError()))
      self.synthesizer.stopSpeaking(at: .immediate)
    }
  }

  private func append(_ buffer: AVAudioBuffer) {
    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
    do {
      try lock.withLock {
        guard outcome == nil else { return }
        lastProgress = .now()
        guard pcm.frameLength > 0 else { return }
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

  private func watchForStall(after delay: TimeInterval) {
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.checkForStall() }
  }

  private func checkForStall() {
    let remaining = lock.withLock { () -> TimeInterval? in
      guard outcome == nil, !synthesisFinished else { return nil }
      let idle = Double(DispatchTime.now().uptimeNanoseconds - lastProgress.uptimeNanoseconds) / 1_000_000_000
      return stallTimeout - idle
    }
    guard let remaining else { return }
    if remaining > 0 {
      watchForStall(after: remaining)
      return
    }
    finish(.failure(TTSError.synthesisFailure("The system voice stopped before it finished the text")))
    synthesizer.stopSpeaking(at: .immediate)
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
    guard let (continuation, result) = settled else { return }
    lifetime.outcomeSettled()
    continuation?.resume(with: result)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    lock.withLock { synthesisFinished = true }
    DispatchQueue.global().asyncAfter(deadline: .now() + finishGrace) { [self] in
      finish(.success(()))
      lifetime.synthesizerStopped()
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    finish(.failure(CancellationError()))
    lifetime.synthesizerStopped()
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
