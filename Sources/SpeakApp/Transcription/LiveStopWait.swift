import SpeakCore
import Foundation

private let logger = SpeakLogger.logger(category: "TranscriptionManager")

/// The one outstanding live stop: the caller's checked continuation and the
/// safety timeout that resumes it if the controller never reports back.
@MainActor
final class LiveStopWait {
  private let sleep: @MainActor (TimeInterval) async throws -> Void
  private var continuation: CheckedContinuation<TranscriptionResult, Error>?
  /// Monotonic token identifying the current stop request. The safety timeout
  /// captures the value at spawn time and only fires if it still matches, so a
  /// stale timeout from an earlier session can never resume a later session's
  /// continuation.
  private var generation = 0
  private var timeoutTask: Task<Void, Never>?

  init(sleep: @escaping @MainActor (TimeInterval) async throws -> Void) {
    self.sleep = sleep
  }

  var isPending: Bool { continuation != nil }

  /// Suspends until `take()` hands the continuation to a delegate callback, or
  /// the timeout fires. `requestStop` runs once the continuation is installed;
  /// `onTimeout` runs just before a timed-out stop is resumed with an error.
  func wait(
    timeout: TimeInterval,
    requestStop: () -> Void,
    onTimeout: @escaping @MainActor () -> Void
  ) async throws -> TranscriptionResult {
    generation += 1
    let generation = generation
    let sleep = sleep
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      requestStop()
      // Safety timeout: if the delegate never calls back, resume with an error
      // rather than hanging forever. Guarded by the generation token so a stale
      // timeout from a previous session can't resume a later session's continuation.
      timeoutTask?.cancel()
      timeoutTask = Task { @MainActor [weak self] in
        try? await sleep(timeout)
        guard let self, !Task.isCancelled,
          self.generation == generation,
          let cont = self.continuation
        else { return }
        logger.error("Safety timeout: continuation not resumed after \(timeout)s, forcing error")
        self.continuation = nil
        self.timeoutTask = nil
        onTimeout()
        cont.resume(throwing: TranscriptionManagerError.liveSessionNotRunning)
      }
    }
  }

  /// Hands over the pending continuation, if any, and cancels its timeout so
  /// the caller can resume it exactly once.
  func take() -> CheckedContinuation<TranscriptionResult, Error>? {
    guard let continuation else { return nil }
    cancelTimeout()
    self.continuation = nil
    return continuation
  }

  /// Fails any pending stop and cancels its timeout.
  func cancel(throwing error: Error) {
    cancelTimeout()
    continuation?.resume(throwing: error)
    continuation = nil
  }

  private func cancelTimeout() {
    timeoutTask?.cancel()
    timeoutTask = nil
  }
}
