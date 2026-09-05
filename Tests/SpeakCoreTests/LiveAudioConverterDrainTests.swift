import AVFoundation
import XCTest

@testable import SpeakCore

/// Cover for issues #849 (macOS controllers) and #872 (the iOS live
/// transcribers, which share this helper from `SpeakCore`).
///
/// Live capture paths retain one `AVAudioConverter` for the
/// whole session and never `reset()` it, so at stop the resampler is still
/// holding the frames whose filter window has not closed. Releasing the
/// converter without an end-of-stream flush throws those frames away and clips
/// the tail of the utterance.
final class LiveAudioConverterDrainTests: XCTestCase {

  private let inputSampleRate = 48_000.0
  private let outputSampleRate = 16_000.0

  private func makeInputFormat() -> AVAudioFormat {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: inputSampleRate, channels: 1) else {
      preconditionFailure("Failed to build 48 kHz float input format")
    }
    return format
  }

  private func makeOutputFormat() -> AVAudioFormat {
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: outputSampleRate,
      channels: 1,
      interleaved: false
    ) else {
      preconditionFailure("Failed to build 16 kHz PCM16 output format")
    }
    return format
  }

  /// A 220 Hz tone chunk, so the resampler has real signal to filter rather
  /// than silence it could shortcut.
  private func makeToneChunk(
    format: AVAudioFormat,
    frames: AVAudioFrameCount,
    startingFrame: Int
  ) -> AVAudioPCMBuffer {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
          let samples = buffer.floatChannelData else {
      preconditionFailure("Failed to build tone chunk")
    }
    buffer.frameLength = frames
    for index in 0..<Int(frames) {
      let time = Double(startingFrame + index) / format.sampleRate
      samples[0][index] = Float(0.25 * sin(2 * Double.pi * 220 * time))
    }
    return buffer
  }

  /// Converts one chunk exactly the way the live processors do: cached
  /// converter, no `reset()`, one input buffer per `convert` call.
  private func convertChunk(
    _ chunk: AVAudioPCMBuffer,
    converter: AVAudioConverter,
    outputFormat: AVAudioFormat
  ) -> Int {
    let ratio = outputFormat.sampleRate / chunk.format.sampleRate
    let capacity = AVAudioFrameCount(ceil(Double(chunk.frameLength) * ratio)) + 1
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
      XCTFail("Failed to allocate conversion output buffer")
      return 0
    }
    output.frameLength = 0

    var error: NSError?
    var didProvideInput = false
    let status = converter.convert(to: output, error: &error) { _, outStatus in
      guard !didProvideInput else {
        outStatus.pointee = .noDataNow
        return nil
      }
      didProvideInput = true
      outStatus.pointee = .haveData
      return chunk
    }
    XCTAssertNotEqual(status, .error)
    XCTAssertNil(error)
    return Int(output.frameLength)
  }

  func testDrainRecoversTheTrailingFramesTheLiveLoopLeavesBehind() {
    let inputFormat = makeInputFormat()
    let outputFormat = makeOutputFormat()
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      XCTFail("Failed to create 48 kHz -> 16 kHz converter")
      return
    }

    let chunkFrames: AVAudioFrameCount = 1024
    let chunkCount = 47
    let totalInputFrames = Int(chunkFrames) * chunkCount

    var framesBeforeDrain = 0
    for index in 0..<chunkCount {
      let chunk = makeToneChunk(
        format: inputFormat,
        frames: chunkFrames,
        startingFrame: index * Int(chunkFrames)
      )
      framesBeforeDrain += convertChunk(chunk, converter: converter, outputFormat: outputFormat)
    }

    let tail = LiveAudioConverterDrain.drain(converter: converter, outputFormat: outputFormat)
    let tailFrames = Int(tail?.frameLength ?? 0)

    XCTAssertGreaterThan(
      tailFrames,
      0,
      "The retained resampler must still owe frames at end of stream; that is the audio issue #849 lost"
    )

    let expectedFrames = totalInputFrames / 3
    XCTAssertLessThan(
      framesBeforeDrain,
      expectedFrames,
      "Without the drain the live loop is short of a full 3:1 decimation of its input"
    )
    XCTAssertGreaterThan(framesBeforeDrain + tailFrames, framesBeforeDrain)

    // The drained total should land on the full decimation within the
    // resampler's own latency — a couple of milliseconds at 16 kHz.
    let tolerance = 64
    XCTAssertLessThanOrEqual(
      abs(framesBeforeDrain + tailFrames - expectedFrames),
      tolerance,
      "Drained output should account for the whole input: got \(framesBeforeDrain + tailFrames), "
        + "expected ~\(expectedFrames)"
    )
  }

  func testDrainedTailCarriesSignalNotSilence() {
    let inputFormat = makeInputFormat()
    let outputFormat = makeOutputFormat()
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      XCTFail("Failed to create 48 kHz -> 16 kHz converter")
      return
    }

    for index in 0..<10 {
      let chunk = makeToneChunk(format: inputFormat, frames: 1024, startingFrame: index * 1024)
      _ = convertChunk(chunk, converter: converter, outputFormat: outputFormat)
    }

    guard let tail = LiveAudioConverterDrain.drain(converter: converter, outputFormat: outputFormat),
          let samples = tail.int16ChannelData else {
      XCTFail("Expected trailing frames from the drained converter")
      return
    }
    let peak = (0..<Int(tail.frameLength)).map { abs(Int(samples[0][$0])) }.max() ?? 0
    XCTAssertGreaterThan(peak, 0, "The trailing frames should be the tail of the tone, not padding")
  }

  func testDrainPCM16DataMatchesTheDrainedFrameCount() {
    let inputFormat = makeInputFormat()
    let outputFormat = makeOutputFormat()
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      XCTFail("Failed to create 48 kHz -> 16 kHz converter")
      return
    }

    for index in 0..<10 {
      let chunk = makeToneChunk(format: inputFormat, frames: 1024, startingFrame: index * 1024)
      _ = convertChunk(chunk, converter: converter, outputFormat: outputFormat)
    }

    guard let data = LiveAudioConverterDrain.drainPCM16Data(
      converter: converter,
      outputFormat: outputFormat
    ) else {
      XCTFail("Expected PCM16 bytes from the drained converter")
      return
    }
    XCTAssertGreaterThan(data.count, 0)
    XCTAssertEqual(data.count % MemoryLayout<Int16>.size, 0)
  }

  func testByteDrainsRejectUnsupportedFormatsWithoutConsumingTheTail() throws {
    for commonFormat in [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatFloat32] {
      for (channels, interleaved) in [(AVAudioChannelCount(2), false), (1, true), (2, true)] {
        let output = try XCTUnwrap(AVAudioFormat(
          commonFormat: commonFormat, sampleRate: outputSampleRate,
          channels: channels, interleaved: interleaved
        ))
        let input = makeInputFormat()
        let converter = try XCTUnwrap(AVAudioConverter(from: input, to: output))
        for index in 0..<10 {
          let chunk = makeToneChunk(format: input, frames: 1024, startingFrame: index * 1024)
          _ = convertChunk(chunk, converter: converter, outputFormat: output)
        }

        XCTAssertNil(LiveAudioConverterDrain.drainPCM16Data(converter: converter, outputFormat: output))
        XCTAssertNil(LiveAudioConverterDrain.drainFloat32Data(converter: converter, outputFormat: output))
        let tail = try XCTUnwrap(LiveAudioConverterDrain.drain(converter: converter, outputFormat: output))
        XCTAssertGreaterThan(tail.frameLength, 0, "Rejecting a byte format must preserve its multichannel tail")
        XCTAssertEqual(tail.format, output)
      }
    }
  }

  func testWrongSampleTypeAndMismatchedFormatDoNotConsumePCM16Tail() throws {
    let input = makeInputFormat()
    let output = makeOutputFormat()
    let converter = try XCTUnwrap(AVAudioConverter(from: input, to: output))
    for index in 0..<10 {
      let chunk = makeToneChunk(format: input, frames: 1024, startingFrame: index * 1024)
      _ = convertChunk(chunk, converter: converter, outputFormat: output)
    }

    XCTAssertNil(LiveAudioConverterDrain.drainFloat32Data(converter: converter, outputFormat: output))
    XCTAssertNil(LiveAudioConverterDrain.drain(converter: converter, outputFormat: input))
    XCTAssertNil(LiveAudioConverterDrain.drain(converter: converter, outputFormat: output, frameCapacity: 0))
    XCTAssertNotNil(LiveAudioConverterDrain.drainPCM16Data(converter: converter, outputFormat: output))
  }

  func testDrainingAnAlreadyDrainedConverterYieldsNothing() {
    let inputFormat = makeInputFormat()
    let outputFormat = makeOutputFormat()
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      XCTFail("Failed to create 48 kHz -> 16 kHz converter")
      return
    }

    for index in 0..<10 {
      let chunk = makeToneChunk(format: inputFormat, frames: 1024, startingFrame: index * 1024)
      _ = convertChunk(chunk, converter: converter, outputFormat: outputFormat)
    }

    XCTAssertNotNil(LiveAudioConverterDrain.drain(converter: converter, outputFormat: outputFormat))
    XCTAssertNil(
      LiveAudioConverterDrain.drain(converter: converter, outputFormat: outputFormat),
      "A drained converter is finished; controllers release it rather than reuse it"
    )
  }

  func testDrainOfAnUnusedConverterIsSafe() {
    let inputFormat = makeInputFormat()
    let outputFormat = makeOutputFormat()
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      XCTFail("Failed to create 48 kHz -> 16 kHz converter")
      return
    }

    let tail = LiveAudioConverterDrain.drain(converter: converter, outputFormat: outputFormat)
    XCTAssertEqual(Int(tail?.frameLength ?? 0), 0, "A converter that never saw input owes nothing")
  }
}

/// The retained-converter half of the same fix: one converter per session,
/// rebuilt only when the input format changes, and released by the drain.
final class LiveConverterCacheTests: XCTestCase {

  private func makeInputFormat(sampleRate: Double = 48_000) -> AVAudioFormat {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
      preconditionFailure("Failed to build float input format")
    }
    return format
  }

  private func makeOutputFormat() -> AVAudioFormat {
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    ) else {
      preconditionFailure("Failed to build 16 kHz PCM16 output format")
    }
    return format
  }

  private func feedTone(_ cache: LiveConverterCache, input: AVAudioFormat, output: AVAudioFormat) {
    guard let converter = cache.converter(from: input, to: output),
          let chunk = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 1024),
          let samples = chunk.floatChannelData,
          let sink = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 512) else {
      return XCTFail("Failed to set up conversion")
    }
    chunk.frameLength = 1024
    for index in 0..<1024 {
      samples[0][index] = Float(0.25 * sin(2 * Double.pi * 220 * Double(index) / input.sampleRate))
    }
    var error: NSError?
    var didProvideInput = false
    _ = converter.convert(to: sink, error: &error) { _, outStatus in
      guard !didProvideInput else {
        outStatus.pointee = .noDataNow
        return nil
      }
      didProvideInput = true
      outStatus.pointee = .haveData
      return chunk
    }
  }

  func testConverterIsBuiltOnceAndReusedAcrossChunks() {
    let cache = LiveConverterCache()
    let input = makeInputFormat()
    let output = makeOutputFormat()

    let first = cache.converter(from: input, to: output)
    let second = cache.converter(from: input, to: output)
    XCTAssertNotNil(first)
    XCTAssertTrue(first === second, "Rebuilding per chunk would throw away the resampler's filter history")
  }

  func testConverterIsRebuiltWhenTheInputFormatChanges() {
    let cache = LiveConverterCache()
    let output = makeOutputFormat()

    let first = cache.converter(from: makeInputFormat(sampleRate: 48_000), to: output)
    let second = cache.converter(from: makeInputFormat(sampleRate: 44_100), to: output)
    XCTAssertNotNil(first)
    XCTAssertNotNil(second)
    XCTAssertFalse(first === second, "A device switch needs a converter for the new input format")
  }

  func testDrainReleasesTheConverterSoTheNextSessionStartsClean() {
    let cache = LiveConverterCache()
    let input = makeInputFormat()
    let output = makeOutputFormat()

    feedTone(cache, input: input, output: output)
    let used = cache.converter(from: input, to: output)

    XCTAssertNotNil(cache.drainPCM16(), "The retained converter still owed trailing frames at stop")
    XCTAssertNil(cache.drainPCM16(), "Draining twice must not re-emit or resurrect the converter")

    let afterDrain = cache.converter(from: input, to: output)
    XCTAssertFalse(afterDrain === used, "A drained converter is finished; the next session gets a fresh one")
  }

  /// The iOS `SharedClientLiveTranscriber` resamples to float32 and converts
  /// to PCM16 itself, so it drains buffers rather than bytes (issue #872).
  func testDrainReturnsTheTrailingBufferForFloat32SendPaths() {
    let cache = LiveConverterCache()
    let input = makeInputFormat()
    guard let output = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
      return XCTFail("Failed to build 16 kHz float output format")
    }

    feedTone(cache, input: input, output: output)
    let used = cache.converter(from: input, to: output)

    guard let tail = cache.drain() else {
      return XCTFail("The retained converter still owed trailing frames at stop")
    }
    XCTAssertGreaterThan(tail.frameLength, 0)
    XCTAssertEqual(tail.format.sampleRate, output.sampleRate)
    XCTAssertNotNil(tail.floatChannelData, "The tail must come back in the caller's output format")
    XCTAssertNil(cache.drain(), "Draining twice must not re-emit or resurrect the converter")
    XCTAssertFalse(
      cache.converter(from: input, to: output) === used,
      "A drained converter is finished; the next session gets a fresh one"
    )
  }

  func testResetDropsTheConverterWithoutDraining() {
    let cache = LiveConverterCache()
    let input = makeInputFormat()
    let output = makeOutputFormat()

    feedTone(cache, input: input, output: output)
    cache.reset()
    XCTAssertNil(cache.drainPCM16(), "reset() is the no-audio teardown path; there is nothing left to flush")
  }
}
