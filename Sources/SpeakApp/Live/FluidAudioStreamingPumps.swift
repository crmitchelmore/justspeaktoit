@preconcurrency import AVFoundation
import Foundation

/// Terminal accounting for one `FluidAudioBufferPump` run: how much captured
/// audio the bounded queue discarded under processing pressure and the error
/// (if any) that terminated the consumer. Returned from `finish()` so the
/// controller observes the pump's terminal state synchronously instead of
/// racing an unstructured error callback (issue #715). The diagnostics are
/// privacy-safe: counts and durations only, never audio or transcript content.
struct FluidAudioPumpOutcome: Sendable {
  var droppedBufferCount = 0
  var droppedAudioSeconds: TimeInterval = 0
  var queuedBufferHighWaterMark = 0
  var processingError: (any Error)?

  var isLossy: Bool { droppedBufferCount > 0 }
}

enum FluidAudioTranscriptEvent: Sendable {
  case partial(String)
  case utteranceBoundary(String)
}

/// Serialises transcript callbacks from the FluidAudio actor onto a single
/// consumer so delegate delivery stays ordered.
final class FluidAudioTranscriptPump: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncStream<FluidAudioTranscriptEvent>.Continuation?
  private var consumerTask: Task<Void, Never>?

  func start(onEvent: @escaping @Sendable (FluidAudioTranscriptEvent) async -> Void) {
    let pair = AsyncStream<FluidAudioTranscriptEvent>.makeStream(bufferingPolicy: .unbounded)
    lock.lock()
    continuation = pair.continuation
    lock.unlock()
    consumerTask = Task {
      for await event in pair.stream {
        await onEvent(event)
      }
    }
  }

  func enqueue(_ event: FluidAudioTranscriptEvent) {
    lock.lock()
    let continuation = continuation
    lock.unlock()
    continuation?.yield(event)
  }

  func finish() async {
    let continuation = takeContinuation()
    continuation?.finish()
    await consumerTask?.value
    consumerTask = nil
  }

  private func takeContinuation() -> AsyncStream<FluidAudioTranscriptEvent>.Continuation? {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    return continuation
  }
}

/// Feeds captured microphone buffers to the FluidAudio processor through a
/// bounded queue. Backpressure accounting (dropped buffers, dropped audio
/// duration, queue high-water mark) and the consumer's terminal error are all
/// part of `finish()` so a stop can never observe success before a concurrent
/// processing failure is visible.
final class FluidAudioBufferPump: @unchecked Sendable {
  static let bufferCapacity = 32

  private let lock = NSLock()
  private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
  private var consumerTask: Task<Void, Never>?
  private var failed = false
  private var outcome = FluidAudioPumpOutcome()

  func start(
    process: @escaping @Sendable (AVAudioPCMBuffer) async throws -> Void,
    onError: @escaping @Sendable (any Error) -> Void
  ) {
    let pair = AsyncStream<AVAudioPCMBuffer>.makeStream(
      bufferingPolicy: .bufferingNewest(Self.bufferCapacity)
    )
    lock.lock()
    continuation = pair.continuation
    failed = false
    outcome = FluidAudioPumpOutcome()
    lock.unlock()

    consumerTask = Task {
      do {
        for await buffer in pair.stream {
          try await process(buffer)
        }
      } catch {
        let continuation = self.recordFailure(error)
        continuation?.finish()
        onError(error)
      }
    }
  }

  func enqueue(_ buffer: AVAudioPCMBuffer) {
    guard let copiedBuffer = Self.copy(buffer) else { return }
    lock.lock()
    let continuation = failed ? nil : continuation
    lock.unlock()
    guard let continuation else { return }
    switch continuation.yield(copiedBuffer) {
    case .enqueued(let remaining):
      recordOccupancy(Self.bufferCapacity - remaining)
    case .dropped(let droppedBuffer):
      recordDrop(of: droppedBuffer)
    case .terminated:
      break
    @unknown default:
      break
    }
  }

  /// Terminates intake, waits for the consumer to drain, and returns the
  /// pump's terminal outcome including any processing error.
  func finish() async -> FluidAudioPumpOutcome {
    let continuation = takeContinuation()
    continuation?.finish()
    await consumerTask?.value
    consumerTask = nil
    lock.lock()
    let outcome = outcome
    lock.unlock()
    return outcome
  }

  private func recordOccupancy(_ occupancy: Int) {
    lock.lock()
    outcome.queuedBufferHighWaterMark = max(outcome.queuedBufferHighWaterMark, occupancy)
    lock.unlock()
  }

  private func recordDrop(of buffer: AVAudioPCMBuffer) {
    let sampleRate = buffer.format.sampleRate
    let seconds = sampleRate > 0 ? Double(buffer.frameLength) / sampleRate : 0
    lock.lock()
    outcome.droppedBufferCount += 1
    outcome.droppedAudioSeconds += seconds
    outcome.queuedBufferHighWaterMark = Self.bufferCapacity
    lock.unlock()
  }

  private func recordFailure(_ error: any Error) -> AsyncStream<AVAudioPCMBuffer>.Continuation? {
    lock.lock()
    failed = true
    if outcome.processingError == nil {
      outcome.processingError = error
    }
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    return continuation
  }

  private func takeContinuation() -> AsyncStream<AVAudioPCMBuffer>.Continuation? {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    return continuation
  }

  private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let frameLength = buffer.frameLength
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frameLength) else {
      return nil
    }
    copy.frameLength = frameLength
    let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
    let destination = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: copy.audioBufferList))
    for index in 0..<min(source.count, destination.count) {
      guard let sourceData = source[index].mData, let destinationData = destination[index].mData else {
        continue
      }
      let copiedByteCount = min(
        Int(source[index].mDataByteSize),
        Int(destination[index].mDataByteSize)
      )
      destinationData.copyMemory(
        from: sourceData,
        byteCount: copiedByteCount
      )
      destination[index].mDataByteSize = UInt32(copiedByteCount)
    }
    return copy
  }
}
