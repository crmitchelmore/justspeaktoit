import AVFoundation
import Foundation
import SpeakCore

/// Pool of reusable copy buffers so the audio tap never allocates on the
/// real-time audio thread.
///
/// Live transcription controllers copy every tap buffer before handing it to
/// their processing queue. Allocating an `AVAudioPCMBuffer` for that copy on
/// the render thread can block (it mallocs and zero-fills), so instead each
/// controller checks a buffer out of this pool and recycles it once the copy
/// has been converted and sent.
///
/// `buffer(format:frameCapacity:)` only reuses a pooled buffer whose format
/// matches exactly and whose capacity is large enough; otherwise it allocates a
/// fresh one, which is then eligible for pooling when recycled. The pool holds
/// at most `maximumBuffers` idle buffers so a burst of oversized requests
/// cannot grow the free list without bound.
///
/// ## Overload policy
///
/// Recycling alone bounds nothing when the *consumer* falls behind: each
/// checked-out buffer is queued for serial processing, so a processing backlog
/// would otherwise make every subsequent tap allocate another buffer and
/// enqueue it, growing queued audio without limit. `maximumOutstanding`
/// therefore caps how many buffers may be checked out at once. Once the cap is
/// reached `buffer(format:frameCapacity:)` returns `nil`, the tap drops that
/// chunk instead of allocating (it never blocks and never waits on the render
/// thread), and a drop counter is incremented. The counter is summarised in a
/// single log line at session teardown — never per drop, never from the render
/// thread, and never with any audio content.
final class LivePCMBufferPool: @unchecked Sendable {
  /// Fallback outstanding cap for callers that do not know their tap size.
  /// 96 buffers is ~2 s of audio at the common 1024-frame, 48 kHz tap.
  static let defaultMaximumOutstanding = 96

  /// Roughly two seconds of tap callbacks at `tapBufferSize`, assuming a
  /// 48 kHz input. Past two seconds of backlog a live consumer is not going to
  /// catch up, so holding the audio only costs memory and latency.
  static func outstandingLimit(tapBufferSize: AVAudioFrameCount) -> Int {
    let framesPerSecond = 48_000.0
    let bufferedSeconds = 2.0
    let frames = Double(max(tapBufferSize, 1))
    return max(4, Int((framesPerSecond * bufferedSeconds / frames).rounded()))
  }

  private let lock = NSLock()
  private let maximumBuffers: Int
  private let maximumOutstanding: Int
  private let label: String
  private var buffers: [AVAudioPCMBuffer] = []
  private var outstanding = 0
  private var droppedChunks = 0

  init(
    maximumBuffers: Int,
    maximumOutstanding: Int = LivePCMBufferPool.defaultMaximumOutstanding,
    label: String = "live-audio"
  ) {
    self.maximumBuffers = maximumBuffers
    self.maximumOutstanding = max(1, maximumOutstanding)
    self.label = label
  }

  convenience init(maximumBuffers: Int, tapBufferSize: AVAudioFrameCount, label: String) {
    self.init(
      maximumBuffers: maximumBuffers,
      maximumOutstanding: LivePCMBufferPool.outstandingLimit(tapBufferSize: tapBufferSize),
      label: label
    )
  }

  /// Buffers currently checked out and not yet recycled.
  var outstandingCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return outstanding
  }

  /// Tap chunks dropped since the last `removeAll()` because the outstanding
  /// cap was reached.
  var droppedChunkCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return droppedChunks
  }

  /// Checks a buffer out of the pool, or returns `nil` when the consumer is so
  /// far behind that admitting more audio would just grow the backlog. A `nil`
  /// return means "drop this chunk"; it is never an error the caller must
  /// handle beyond skipping the buffer.
  func buffer(format: AVAudioFormat, frameCapacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
    lock.lock()
    defer { lock.unlock() }

    guard outstanding < maximumOutstanding else {
      droppedChunks += 1
      return nil
    }

    if let index = buffers.firstIndex(where: { $0.format == format && $0.frameCapacity >= frameCapacity }) {
      let buffer = buffers.remove(at: index)
      buffer.frameLength = 0
      outstanding += 1
      return buffer
    }

    guard let allocated = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
      return nil
    }
    outstanding += 1
    return allocated
  }

  func recycle(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    defer { lock.unlock() }

    outstanding = max(0, outstanding - 1)
    guard buffers.count < maximumBuffers else { return }
    buffer.frameLength = 0
    buffers.append(buffer)
  }

  /// Clears the free list at session teardown and emits the one-and-only
  /// overload summary for the session that just ended.
  func removeAll() {
    lock.lock()
    let dropped = droppedChunks
    droppedChunks = 0
    outstanding = 0
    buffers.removeAll(keepingCapacity: true)
    let poolLabel = label
    let cap = maximumOutstanding
    lock.unlock()

    guard dropped > 0 else { return }
    LivePCMBufferPool.logger.warning(
      """
      Dropped \(dropped, privacy: .public) tap buffers for \
      \(poolLabel, privacy: .public): audio processing fell more than \
      \(cap, privacy: .public) buffers behind the tap
      """
    )
  }

  private static let logger = SpeakLogger.logger(category: "LivePCMBufferPool")
}
