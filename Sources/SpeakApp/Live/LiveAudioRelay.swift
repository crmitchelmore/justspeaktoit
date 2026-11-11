import Foundation

/// Holds microphone buffers that arrive before their consumer is ready, then
/// hands them over in capture order (#614).
///
/// The SpeechAnalyzer live path starts the audio engine while the analyzer is
/// still being set up, as legacy Apple Speech does with its recognition
/// request. Without this, the analyzer's setup and the engine start ran one
/// after the other, ahead of the first buffer.
final class LiveAudioRelay<Buffer>: @unchecked Sendable {
  /// About 30 s of 1024-frame buffers at 48 kHz. Setup normally finishes well
  /// inside a second; the cap only bounds memory if it stalls.
  static var defaultPendingLimit: Int { 1_500 }

  private let lock = NSLock()
  private let pendingLimit: Int
  private var pending: [Buffer] = []
  private var sink: ((Buffer) -> Void)?
  private var isClosed = false
  private var dropped = 0

  init(pendingLimit: Int = defaultPendingLimit) {
    self.pendingLimit = max(0, pendingLimit)
  }

  /// Delivers straight to the consumer once attached; queues until then.
  /// The consumer runs under the lock, so a flush and a live buffer can never
  /// reach it out of order.
  func send(_ buffer: Buffer) {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed else { return }
    if let sink {
      sink(buffer)
    } else if pending.count < pendingLimit {
      pending.append(buffer)
    } else {
      dropped += 1
    }
  }

  /// Flushes the queued buffers into `sink`, in order, then routes every later
  /// buffer to it directly. Only the first attach takes effect.
  func attach(_ sink: @escaping (Buffer) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed, self.sink == nil else { return }
    for buffer in pending { sink(buffer) }
    pending.removeAll()
    self.sink = sink
  }

  /// Drops queued buffers and ignores everything sent afterwards.
  func close() {
    lock.lock()
    defer { lock.unlock() }
    isClosed = true
    pending.removeAll()
    sink = nil
  }

  var pendingCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return pending.count
  }

  /// Buffers lost because the queue was full before a consumer attached.
  var droppedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return dropped
  }
}
