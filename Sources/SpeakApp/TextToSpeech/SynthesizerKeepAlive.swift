import Foundation

/// Keeps the owner of an `AVSpeechSynthesizer` alive until the synthesizer
/// reports that it stopped.
///
/// The synthesizer delivers its delegate callbacks from blocks queued on the
/// main queue that do not keep the delegate alive. Freeing the owner while one
/// is queued crashes the process in `swift_unknownObjectWeakInit`, so the
/// retain is never bounded while synthesis runs, however long the text. Only
/// once the outcome has settled does a grace period start, covering a
/// synthesizer that never reports stopping.
final class SynthesizerKeepAlive<Owner: AnyObject>: @unchecked Sendable {
  typealias Schedule = (TimeInterval, @escaping @Sendable () -> Void) -> Void

  private let lock = NSLock()
  private var owner: Owner?
  private var fallbackScheduled = false
  private let grace: TimeInterval
  private let schedule: Schedule
  private let drop: (Owner) -> Void

  /// `drop` receives the last retain once it is released; the default frees
  /// the owner on the main queue, never from inside one of its callbacks.
  init(
    grace: TimeInterval,
    schedule: @escaping Schedule = { delay, work in
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    },
    drop: @escaping (Owner) -> Void = { owner in DispatchQueue.main.async { withExtendedLifetime(owner) {} } }
  ) {
    self.grace = grace
    self.schedule = schedule
    self.drop = drop
  }

  func retain(_ owner: Owner) {
    lock.withLock { self.owner = owner }
  }

  /// Starts the bounded wait for the synthesizer to report it stopped.
  func outcomeSettled() {
    let shouldSchedule = lock.withLock { () -> Bool in
      guard owner != nil, !fallbackScheduled else { return false }
      fallbackScheduled = true
      return true
    }
    guard shouldSchedule else { return }
    schedule(grace) { [self] in synthesizerStopped() }
  }

  func synthesizerStopped() {
    let retained = lock.withLock { () -> Owner? in
      defer { owner = nil }
      return owner
    }
    if let retained { drop(retained) }
  }

  var isRetaining: Bool { lock.withLock { owner != nil } }
}
