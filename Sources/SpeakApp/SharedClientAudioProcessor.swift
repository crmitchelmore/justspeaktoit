import AVFoundation
import Foundation
import SpeakCore

// Split out of `SharedClientLiveController.swift` to keep that file inside the
// project's 400-line budget. Module-internal rather than `private` now that it
// lives in its own file; it has no callers outside the shared-client path.

/// Copies each tap buffer out of a pool and converts it off the render
/// thread, so the audio callback never allocates or blocks.
///
/// Mirrors the per-provider controllers on macOS: one converter cached per
/// input format, one reusable output buffer, and no `converter.reset()`
/// between chunks.
final class SharedClientAudioProcessor: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.speak.app.sharedClient.audioProcessing")
  private let copyBufferPool = LivePCMBufferPool(
    maximumBuffers: 4,
    tapBufferSize: 4096,
    label: "shared-client"
  )
  private let logger = SpeakLogger.logger(category: "SharedClientLiveController")
  private var isRunning = false
  private let converterCache = LiveConverterCache()
  private var reusableOutputBuffer: AVAudioPCMBuffer?

  func setRunning(_ running: Bool) {
    queue.sync {
      isRunning = running
      if !running {
        converterCache.reset()
        reusableOutputBuffer = nil
        copyBufferPool.removeAll()
      }
    }
  }

  /// Flushes the retained resampler's trailing frames down the live send path
  /// before the converter is released (issue #849).
  func drainConverterTail(to client: StreamingTranscriptionClient) {
    queue.sync {
      guard let tail = converterCache.drainPCM16() else { return }
      client.sendAudio(tail)
    }
  }

  func handleAudioTap(
    _ buffer: AVAudioPCMBuffer,
    inputFormat: AVAudioFormat,
    outputFormat: AVAudioFormat,
    client: StreamingTranscriptionClient
  ) {
    guard let copied = copyPCMBuffer(buffer) else { return }
    queue.async { [weak self] in
      guard let self else { return }
      defer { self.copyBufferPool.recycle(copied) }
      guard self.isRunning else { return }
      self.convertAndSend(copied, from: inputFormat, to: outputFormat, client: client)
    }
  }

  private func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let frameLength = buffer.frameLength
    guard frameLength > 0,
          let copy = copyBufferPool.buffer(format: buffer.format, frameCapacity: frameLength) else {
      return nil
    }
    copy.frameLength = frameLength
    let source = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: buffer.audioBufferList)
    )
    let destination = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: copy.audioBufferList)
    )
    for index in 0..<min(source.count, destination.count) {
      let sourceBuffer = source[index]
      guard let sourceData = sourceBuffer.mData,
            let destinationData = destination[index].mData else { continue }
      destinationData.copyMemory(from: sourceData, byteCount: Int(sourceBuffer.mDataByteSize))
      destination[index].mDataByteSize = sourceBuffer.mDataByteSize
    }
    return copy
  }

  private func convertAndSend(
    _ buffer: AVAudioPCMBuffer,
    from inputFormat: AVAudioFormat,
    to outputFormat: AVAudioFormat,
    client: StreamingTranscriptionClient
  ) {
    guard let converter = converterCache.converter(from: inputFormat, to: outputFormat) else {
      logger.error("Failed to create audio converter")
      return
    }

    let ratio = outputFormat.sampleRate / inputFormat.sampleRate
    let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1
    let output: AVAudioPCMBuffer
    if let reusable = reusableOutputBuffer, reusable.frameCapacity >= capacity {
      reusable.frameLength = 0
      output = reusable
    } else {
      guard let created = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
        return
      }
      reusableOutputBuffer = created
      output = created
    }

    // No `converter.reset()` between chunks: `LiveConverterCache` owns the
    // retained converter and its end-of-stream drain (see issue #849).
    var conversionError: NSError?
    var didProvideInput = false
    let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
      guard !didProvideInput else {
        outStatus.pointee = .noDataNow
        return nil
      }
      didProvideInput = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, conversionError == nil else {
      logger.error("Audio conversion failed")
      return
    }
    let frameCount = Int(output.frameLength)
    guard frameCount > 0, let samples = output.int16ChannelData else { return }
    client.sendAudio(Data(bytes: samples[0], count: frameCount * 2))
  }
}
