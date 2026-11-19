import SpeakCore
@preconcurrency import AVFoundation
import Foundation
import os.log

#if !APP_STORE
/// Resamples tapped microphone audio to the sidecar's 16 kHz mono Float32 and
/// writes it to the sidecar's stdin. The tap only copies into a bounded pool;
/// conversion and the pipe write happen on this processor's serial queue.
final class SherpaOnnxAudioProcessor: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.github.speakapp.sherpa-onnx.audioProcessing")
  private let copyBufferPool = LivePCMBufferPool(
    maximumBuffers: 4,
    tapBufferSize: 4096,
    label: "sherpa-onnx"
  )
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

  /// Flushes the retained resampler's trailing frames to the sidecar before the
  /// converter is released and stdin is closed (issue #849).
  func drainConverterTail(to writer: FileHandle, logger: Logger) {
    queue.sync {
      guard let tail = converterCache.drainFloat32() else { return }
      do {
        try writer.write(contentsOf: tail)
      } catch {
        let description = error.localizedDescription
        logger.error("Failed to write drained audio to sherpa-onnx: \(description, privacy: .public)")
      }
    }
  }

  func handleAudioTap(
    _ buffer: AVAudioPCMBuffer,
    inputFormat: AVAudioFormat,
    outputFormat: AVAudioFormat,
    writer: FileHandle,
    logger: Logger
  ) {
    guard let copied = copyBufferPool.copy(buffer) else { return }
    queue.async { [weak self] in
      guard let self else { return }
      defer { self.copyBufferPool.recycle(copied) }
      guard self.isRunning else { return }
      self.processAndWriteAudio(copied, from: inputFormat, to: outputFormat, writer: writer, logger: logger)
    }
  }

  private func processAndWriteAudio(
    _ buffer: AVAudioPCMBuffer,
    from inputFormat: AVAudioFormat,
    to outputFormat: AVAudioFormat,
    writer: FileHandle,
    logger: Logger
  ) {
    guard let converter = converterCache.converter(from: inputFormat, to: outputFormat) else {
      logger.error("Failed to create sherpa-onnx audio converter")
      return
    }

    let ratio = outputFormat.sampleRate / inputFormat.sampleRate
    let capacity = AVAudioFrameCount(max(1, Double(buffer.frameLength) * ratio + 32))
    let outputBuffer: AVAudioPCMBuffer
    if let reusableOutputBuffer, reusableOutputBuffer.frameCapacity >= capacity {
      reusableOutputBuffer.frameLength = 0
      outputBuffer = reusableOutputBuffer
    } else {
      guard let newBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
      reusableOutputBuffer = newBuffer
      outputBuffer = newBuffer
    }

    var didProvideInput = false
    var error: NSError?
    let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      if didProvideInput {
        outStatus.pointee = .noDataNow
        return nil
      }
      didProvideInput = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, error == nil, let channelData = outputBuffer.floatChannelData else {
      let errorDescription = error?.localizedDescription ?? "unknown"
      logger.error("sherpa-onnx audio conversion failed: \(errorDescription, privacy: .public)")
      return
    }
    let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Float>.size
    let data = Data(bytes: channelData[0], count: byteCount)
    do {
      try writer.write(contentsOf: data)
    } catch {
      logger.error("Failed to write audio to sherpa-onnx: \(error.localizedDescription, privacy: .public)")
    }
  }
}
#endif
