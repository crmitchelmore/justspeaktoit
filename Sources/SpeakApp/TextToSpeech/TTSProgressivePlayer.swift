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
  private var scheduledFrames = 0
  private var drainContinuation: CheckedContinuation<Void, Never>?

  /// Seconds of audio that may sit scheduled ahead of what has been heard.
  ///
  /// A streaming provider can generate far faster than real time, so without a
  /// ceiling a long utterance accumulates the whole document in scheduled
  /// buffers. Ten seconds is more than enough to ride out a network stall.
  static let scheduledAheadLimit: TimeInterval = 10
  /// Longest one chunk waits for that headroom before being scheduled anyway.
  /// Playback that is paused indefinitely must not stall the socket forever.
  static let headroomWaitLimit: TimeInterval = 5
  private static let headroomPollInterval: TimeInterval = 0.05

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
    scheduledFrames += Int(frameCount)
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { @MainActor in self?.didFinishBuffer(frames: Int(frameCount)) }
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
    scheduledFrames = 0
    isActive = false
    drainContinuation?.resume()
    drainContinuation = nil
  }

  private func didFinishBuffer(frames: Int) {
    scheduledBuffers = max(0, scheduledBuffers - 1)
    scheduledFrames = max(0, scheduledFrames - frames)
    guard scheduledBuffers == 0 else { return }
    drainContinuation?.resume()
    drainContinuation = nil
  }

  /// Seconds of scheduled audio that have not been heard yet.
  var scheduledAheadSeconds: TimeInterval {
    guard let format, format.sampleRate > 0 else { return 0 }
    return Double(scheduledFrames) / format.sampleRate
  }

  /// Waits, up to `headroomWaitLimit`, until the scheduled audio falls back
  /// under the ahead-of-playback ceiling.
  ///
  /// Bounded rather than open-ended: a paused or stalled engine would
  /// otherwise hold a provider socket open indefinitely, which is a worse
  /// failure than briefly exceeding the ceiling.
  func waitForHeadroom(now: () -> Date = Date.init) async {
    let deadline = now().addingTimeInterval(Self.headroomWaitLimit)
    while isActive, scheduledAheadSeconds >= Self.scheduledAheadLimit, now() < deadline {
      try? await Task.sleep(
        nanoseconds: UInt64(Self.headroomPollInterval * 1_000_000_000)
      )
    }
  }
}

extension TTSProgressivePlayer {
  /// Plays a streaming provider's audio as it arrives and answers the finished
  /// result, which is the same complete `TTSResult` the batch path returns.
  ///
  /// Each chunk is scheduled from inside the provider's own callback, which
  /// the provider awaits. That keeps the speech in order without a second
  /// task, lets a full playback queue hold the provider back, and lets a
  /// scheduling failure end the stream: a thrown error — a barge-in
  /// cancellation or a playback failure — stops the engine, discards the
  /// partial audio and reaches the caller as a failed synthesis.
  func speak(
    text: String,
    voice: String,
    settings: TTSSettings,
    using client: any ProgressiveTextToSpeechClient
  ) async throws -> TTSResult {
    try prepare(sampleRate: client.progressiveSampleRate)
    do {
      let result = try await client.synthesizeProgressively(
        text: text, voice: voice, settings: settings
      ) { [weak self] chunk in
        guard let self else { return }
        try await self.schedule(chunk)
      }
      await waitUntilDrained()
      stop()
      return result
    } catch {
      stop()
      throw error
    }
  }

  /// Schedules one arriving chunk, first waiting for playback headroom.
  private func schedule(_ chunk: Data) async throws {
    await waitForHeadroom()
    try Task.checkCancellation()
    try enqueue(chunk)
  }
}
