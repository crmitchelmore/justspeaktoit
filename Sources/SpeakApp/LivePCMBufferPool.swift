import AVFoundation
import Foundation

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
/// at most `maximumBuffers` buffers so a burst of oversized requests cannot
/// grow it without bound.
final class LivePCMBufferPool: @unchecked Sendable {
  private let lock = NSLock()
  private let maximumBuffers: Int
  private var buffers: [AVAudioPCMBuffer] = []

  init(maximumBuffers: Int) {
    self.maximumBuffers = maximumBuffers
  }

  func buffer(format: AVAudioFormat, frameCapacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
    lock.lock()
    defer { lock.unlock() }

    if let index = buffers.firstIndex(where: { $0.format == format && $0.frameCapacity >= frameCapacity }) {
      let buffer = buffers.remove(at: index)
      buffer.frameLength = 0
      return buffer
    }

    return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
  }

  func recycle(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    defer { lock.unlock() }

    guard buffers.count < maximumBuffers else { return }
    buffer.frameLength = 0
    buffers.append(buffer)
  }

  func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    buffers.removeAll(keepingCapacity: true)
  }
}
