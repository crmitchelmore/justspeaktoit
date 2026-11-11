import AVFoundation
import Foundation
import SpeakCore

// Split out of `SharedClientLiveController.swift` to keep that file inside the
// project's 400-line budget. Module-internal rather than `private` now that it
// lives in its own file; it has no callers outside the shared-client path.

/// Copies each tap buffer out of a pool and converts it off the render
/// thread, so the audio callback never allocates or blocks.
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

  func setRunning(_ running: Bool) {
    queue.sync {
      isRunning = running
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
  func installTap(on inputNode: AVAudioInputNode, sampleRate: Int, client: StreamingTranscriptionClient) throws {
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
    setRunning(true)
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

  private func convertAndSend(
    _ buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat, client: StreamingTranscriptionClient
  ) {
    do {
      let pcm = try conversion.pcm16(from: buffer, to: outputFormat)
      guard !pcm.isEmpty else { return }
      client.sendAudio(pcm)
    } catch {
      logger.error("Audio conversion failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}
