import AVFoundation
import Foundation
import SpeakCore

// Split out of `SharedClientLiveController.swift` to keep that file inside the
// project's 400-line budget. Module-internal rather than `private` now that it
// lives in its own file; it has no callers outside the shared-client path.

/// Copies each tap buffer into a pooled buffer and converts it off the render
/// thread. The callback is bounded, not real-time safe: it takes the pool's
/// short lock, allocates a copy buffer on a pool miss (see
/// `LivePCMBufferPool`), enqueues one block on `queue` (which allocates), and
/// drops the chunk rather than waiting when processing falls behind.
///
/// `LivePCM16Conversion` keeps one converter per input format and one
/// reusable output buffer, with no `converter.reset()` between chunks.
final class SharedClientAudioProcessor: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.speak.app.sharedClient.audioProcessing")
  private let copyBufferPool = LivePCMBufferPool(
    maximumBuffers: 4,
    tapBufferSize: 4096,
    label: "shared-client"
  )
  private let logger = SpeakLogger.logger(category: "SharedClientLiveController")
  private var isRunning = false
  private let conversion = LivePCM16Conversion()
  private var conversionFailure: LivePCMConversionFailureReport?

  /// Starting arms `onConversionFailure` for this run; it is told about the
  /// run's first conversion failure only, since later buffers fail the same way.
  func setRunning(_ running: Bool, onConversionFailure: (@Sendable (Error) -> Void)? = nil) {
    queue.sync {
      isRunning = running
      conversionFailure = running ? onConversionFailure.map(LivePCMConversionFailureReport.init) : nil
      if !running {
        conversion.reset()
        copyBufferPool.removeAll()
      }
    }
  }

  /// Flushes the retained resampler's trailing frames down the live send path
  /// before the converter is released (issue #849).
  func drainConverterTail(to client: StreamingTranscriptionClient) {
    queue.sync {
      guard let tail = conversion.drainPCM16() else { return }
      client.sendAudio(tail)
    }
  }

  /// Installs the capture tap that feeds `client` PCM16 mono at `sampleRate`.
  /// The caller's failed-start path removes the tap and stops the engine.
  func installTap(
    on inputNode: AVAudioInputNode, sampleRate: Int, client: StreamingTranscriptionClient,
    onConversionFailure: @escaping @Sendable (Error) -> Void
  ) throws {
    inputNode.removeTap(onBus: 0)
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard audioInputFormatIsUsable(inputFormat) else {
      throw TranscriptionManagerError.noUsableAudioInput
    }
    guard let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true
    ), AVAudioConverter(from: inputFormat, to: targetFormat) != nil else {
      throw TranscriptionManagerError.noUsableAudioInput
    }
    setRunning(true, onConversionFailure: onConversionFailure)
    try inputNode.installTapSafely(onBus: 0, bufferSize: 4096, format: inputFormat) { [self] buffer, _ in
      handleAudioTap(buffer, outputFormat: targetFormat, client: client)
    }
  }

  private func handleAudioTap(
    _ buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat, client: StreamingTranscriptionClient
  ) {
    guard let copied = copyBufferPool.copy(buffer) else { return }
    queue.async { [weak self] in
      guard let self else { return }
      defer { self.copyBufferPool.recycle(copied) }
      guard self.isRunning else { return }
      self.convertAndSend(copied, to: outputFormat, client: client)
    }
  }

  func convertAndSend(
    _ buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat, client: StreamingTranscriptionClient
  ) {
    do {
      let pcm = try conversion.pcm16(from: buffer, to: outputFormat)
      guard !pcm.isEmpty else { return }
      client.sendAudio(pcm)
    } catch {
      guard let report = conversionFailure else { return }
      conversionFailure = nil
      logger.error("Audio conversion failed: \(error.localizedDescription, privacy: .public)")
      report(error)
    }
  }
}
