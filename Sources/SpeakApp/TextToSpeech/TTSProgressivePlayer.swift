import AVFoundation
import Foundation
import SpeakCore

/// Plays linear PCM as it arrives, so speech starts before synthesis finishes.
///
/// The file players the other providers use cannot open a growing file, so a
/// progressive provider schedules its chunks on an `AVAudioPlayerNode` instead.
/// One instance owns one utterance: `prepare` opens the engine, `enqueue`
/// schedules whatever whole samples have arrived, and `stop` tears everything
/// down. A partial sample at the end of a chunk is held until its remaining
/// bytes arrive, because scheduling half a frame would click.
@MainActor
final class TTSProgressivePlayer {
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var format: AVAudioFormat?
  private var pending = Data()
  private var scheduledBuffers = 0
  private var drainContinuation: CheckedContinuation<Void, Never>?

  /// Whether an utterance is currently scheduled or playing.
  private(set) var isActive = false

  func prepare(sampleRate: Int) throws {
    stop()
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: Double(sampleRate),
      channels: 1,
      interleaved: true
    ) else {
      throw TTSError.audioPlaybackFailure
    }
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    do {
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: format)
      try engine.start()
      player.play()
    } catch {
      player.stop()
      engine.stop()
      throw TTSError.audioPlaybackFailure
    }
    self.engine = engine
    self.player = player
    self.format = format
    self.isActive = true
  }

  /// Schedules every whole sample in `data`, holding a trailing partial sample
  /// for the next chunk. Returns `false` when there was nothing whole to play
  /// yet, which is not a failure.
  @discardableResult
  func enqueue(_ data: Data) throws -> Bool {
    guard let format, let player, isActive else { return false }
    pending.append(data)
    let sampleSize = MemoryLayout<Int16>.size
    let wholeByteCount = pending.count - pending.count % sampleSize
    guard wholeByteCount > 0 else { return false }
    let payload = pending.prefix(wholeByteCount)
    pending.removeFirst(wholeByteCount)

    let frameCount = AVAudioFrameCount(wholeByteCount / sampleSize)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
      let channel = buffer.int16ChannelData?[0]
    else {
      throw TTSError.audioPlaybackFailure
    }
    payload.withUnsafeBytes { source in
      guard let baseAddress = source.baseAddress else { return }
      memcpy(channel, baseAddress, wholeByteCount)
    }
    buffer.frameLength = frameCount
    scheduledBuffers += 1
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { @MainActor in self?.didFinishBuffer() }
    }
    if !player.isPlaying { player.play() }
    return true
  }

  /// Waits until every scheduled buffer has been heard, so a caller can report
  /// playback finished rather than guessing from the synthesis time.
  func waitUntilDrained() async {
    guard isActive, scheduledBuffers > 0 else { return }
    await withCheckedContinuation { continuation in
      self.drainContinuation = continuation
    }
  }

  func pause() {
    player?.pause()
  }

  func resume() {
    guard isActive else { return }
    if engine?.isRunning == false { try? engine?.start() }
    if player?.isPlaying == false { player?.play() }
  }

  func stop() {
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    format = nil
    pending.removeAll(keepingCapacity: false)
    scheduledBuffers = 0
    isActive = false
    drainContinuation?.resume()
    drainContinuation = nil
  }

  private func didFinishBuffer() {
    scheduledBuffers = max(0, scheduledBuffers - 1)
    guard scheduledBuffers == 0 else { return }
    drainContinuation?.resume()
    drainContinuation = nil
  }
}

extension TTSProgressivePlayer {
  /// Plays a streaming provider's audio as it arrives and answers the finished
  /// result, which is the same complete `TTSResult` the batch path returns.
  ///
  /// The chunks travel through an `AsyncStream` rather than one task per chunk,
  /// because independent tasks would be free to run out of order and scramble
  /// the speech. A thrown error — including the cancellation a barge-in causes —
  /// stops the engine and discards the partial audio.
  func speak(
    text: String,
    voice: String,
    settings: TTSSettings,
    using client: any ProgressiveTextToSpeechClient
  ) async throws -> TTSResult {
    try prepare(sampleRate: client.progressiveSampleRate)
    let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    let playback = Task { @MainActor in
      for await chunk in chunks { try? enqueue(chunk) }
    }
    do {
      let result = try await client.synthesizeProgressively(
        text: text, voice: voice, settings: settings
      ) { chunk in
        continuation.yield(chunk)
      }
      continuation.finish()
      await playback.value
      await waitUntilDrained()
      stop()
      return result
    } catch {
      continuation.finish()
      playback.cancel()
      stop()
      throw error
    }
  }
}
