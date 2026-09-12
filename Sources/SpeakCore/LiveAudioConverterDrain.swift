import AVFoundation
import Foundation

/// End-of-stream flush for the `AVAudioConverter` instances the live capture
/// paths retain across tap buffers — the macOS controllers in `SpeakApp` and
/// the iOS live transcribers in `SpeakiOS` both use it.
///
/// Live audio processors deliberately keep one converter per input format and
/// never call `reset()` between tap buffers, so the resampler's filter history
/// spans the whole session. That history is also why the converter holds back
/// output: at any moment the last few milliseconds of input have not yet been
/// through a complete filter window, so their output frames are still inside
/// the converter. Dropping the converter at stop without flushing it discards
/// those frames, which clips the tail of a short utterance.
///
/// `drain(converter:outputFormat:)` signals `.endOfStream` to the converter and
/// collects everything it still owes. The converter's state is finished
/// afterwards, so callers must release it rather than reuse it.
public enum LiveAudioConverterDrain {
  /// Frames requested per drain pass. 4096 frames is ~256 ms at 16 kHz, far
  /// more than any resampler's latency, so one pass normally suffices.
  public static let drainFrameCapacity: AVAudioFrameCount = 4096

  /// Upper bound on drain passes so a converter that keeps reporting
  /// `.haveData` can never spin forever on the stop path.
  public static let maximumDrainPasses = 8

  /// Flushes `converter` and returns its trailing frames, or `nil` when the
  /// converter had nothing left to give.
  public static func drain(
    converter: AVAudioConverter,
    outputFormat: AVAudioFormat,
    frameCapacity: AVAudioFrameCount = drainFrameCapacity
  ) -> AVAudioPCMBuffer? {
    guard outputFormat == converter.outputFormat, frameCapacity > 0 else { return nil }
    var collected: [AVAudioPCMBuffer] = []
    var totalFrames = 0

    for _ in 0..<maximumDrainPasses {
      guard let scratch = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
        break
      }
      scratch.frameLength = 0

      var error: NSError?
      let status = converter.convert(to: scratch, error: &error) { _, outStatus in
        outStatus.pointee = .endOfStream
        return nil
      }

      if scratch.frameLength > 0 {
        collected.append(scratch)
        totalFrames += Int(scratch.frameLength)
      }

      // `.haveData` means the scratch buffer filled up and the converter may
      // still be holding more; anything else (including `.endOfStream`,
      // `.inputRanDry` and `.error`) means we are done.
      guard status == .haveData, error == nil, scratch.frameLength > 0 else { break }
    }

    guard totalFrames > 0 else { return nil }
    if collected.count == 1 { return collected[0] }
    return concatenate(collected, totalFrames: totalFrames, format: outputFormat)
  }

  /// Convenience wrapper for the PCM16 send paths: flushes `converter` and
  /// returns the trailing frames as little-endian 16-bit mono samples.
  /// Both mono layouts are supported. Unsupported formats return `nil`
  /// without consuming the converter's tail.
  public static func drainPCM16Data(
    converter: AVAudioConverter,
    outputFormat: AVAudioFormat
  ) -> Data? {
    guard outputFormat.commonFormat == .pcmFormatInt16,
          outputFormat.channelCount == 1 else { return nil }
    guard let tail = drain(converter: converter, outputFormat: outputFormat),
          tail.frameLength > 0,
          let samples = tail.audioBufferList.pointee.mBuffers.mData else {
      return nil
    }
    return Data(bytes: samples, count: Int(tail.frameLength) * MemoryLayout<Int16>.size)
  }

  /// Convenience wrapper for the mono float32 sidecar path.
  /// Both mono layouts are supported. Unsupported formats return `nil`
  /// without consuming the converter's tail.
  public static func drainFloat32Data(
    converter: AVAudioConverter,
    outputFormat: AVAudioFormat
  ) -> Data? {
    guard outputFormat.commonFormat == .pcmFormatFloat32,
          outputFormat.channelCount == 1 else { return nil }
    guard let tail = drain(converter: converter, outputFormat: outputFormat),
          tail.frameLength > 0,
          let samples = tail.audioBufferList.pointee.mBuffers.mData else {
      return nil
    }
    return Data(bytes: samples, count: Int(tail.frameLength) * MemoryLayout<Float>.size)
  }

  private static func concatenate(
    _ buffers: [AVAudioPCMBuffer],
    totalFrames: Int,
    format: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
    guard bytesPerFrame > 0,
          let merged = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
      return buffers.first
    }
    merged.frameLength = AVAudioFrameCount(totalFrames)

    let destination = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: merged.audioBufferList)
    )
    var writtenFrames = 0
    for buffer in buffers {
      let source = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: buffer.audioBufferList)
      )
      for index in 0..<min(source.count, destination.count) {
        guard let sourceData = source[index].mData,
              let destinationData = destination[index].mData else { continue }
        destinationData.advanced(by: writtenFrames * bytesPerFrame)
          .copyMemory(from: sourceData, byteCount: Int(buffer.frameLength) * bytesPerFrame)
      }
      writtenFrames += Int(buffer.frameLength)
    }
    return merged
  }
}

/// The retained `AVAudioConverter` a live audio processor keeps for a session,
/// plus its end-of-stream flush.
///
/// Every live controller had the same three fields (converter, input format,
/// output format), the same get-or-create block and the same teardown; this
/// holds them in one place so the drain cannot be forgotten on one path and
/// remembered on another.
///
/// A cache is owned by exactly one processor and only ever touched from that
/// processor's serial audio queue, so it needs no locking of its own. That
/// single-queue ownership is also what `@unchecked Sendable` asserts: the cache
/// crosses an isolation boundary once, when the capture path hands it to the
/// audio-processing queue, and every access after that happens on that queue.
public final class LiveConverterCache: @unchecked Sendable {
  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?
  private var outputFormat: AVAudioFormat?

  public init() {}

  /// Returns the converter for `input` → `output`, creating it on first use
  /// and reusing it for every later tap buffer.
  ///
  /// Reuse is deliberate: `reset()`ing between chunks would wipe the
  /// resampler's filter history, which audibly clicks at chunk boundaries and
  /// pays the re-priming cost on every chunk. A change of input format
  /// (a device switch) builds a fresh converter.
  public func converter(from input: AVAudioFormat, to output: AVAudioFormat) -> AVAudioConverter? {
    if let converter, inputFormat == input, outputFormat == output {
      return converter
    }
    guard let created = AVAudioConverter(from: input, to: output) else { return nil }
    converter = created
    inputFormat = input
    outputFormat = output
    return created
  }

  /// Flushes the converter at end of stream and returns its trailing frames,
  /// releasing the (now finished) converter.
  ///
  /// For send paths whose output format already matches the wire format,
  /// ``drainPCM16()`` and ``drainFloat32()`` return bytes directly; this is for
  /// callers that post-process the frames (iOS's float32 → PCM16 conversion).
  public func drain() -> AVAudioPCMBuffer? {
    guard let (converter, format) = takeConverter() else { return nil }
    return LiveAudioConverterDrain.drain(converter: converter, outputFormat: format)
  }

  /// Flushes the converter at end of stream and returns its trailing frames as
  /// PCM16 bytes, releasing the (now finished) converter.
  public func drainPCM16() -> Data? {
    guard outputFormat?.commonFormat == .pcmFormatInt16, outputFormat?.channelCount == 1 else { return nil }
    guard let (converter, format) = takeConverter() else { return nil }
    return LiveAudioConverterDrain.drainPCM16Data(converter: converter, outputFormat: format)
  }

  /// Float32 counterpart of ``drainPCM16()`` for the sidecar path.
  public func drainFloat32() -> Data? {
    guard outputFormat?.commonFormat == .pcmFormatFloat32, outputFormat?.channelCount == 1 else { return nil }
    guard let (converter, format) = takeConverter() else { return nil }
    return LiveAudioConverterDrain.drainFloat32Data(converter: converter, outputFormat: format)
  }

  /// Drops the converter without flushing it. Only for teardown paths that
  /// have already drained, or that never had audio worth keeping.
  public func reset() {
    converter = nil
    inputFormat = nil
    outputFormat = nil
  }

  private func takeConverter() -> (AVAudioConverter, AVAudioFormat)? {
    guard let converter, let outputFormat else { return nil }
    reset()
    return (converter, outputFormat)
  }
}
