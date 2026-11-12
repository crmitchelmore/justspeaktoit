import Foundation

/// Starts the live-input preparation on the first hotkey press, so the work a
/// session start does before it may open the microphone is already done when
/// the hold or the second tap of a double tap is recognised (#611).
///
/// Unlike `HotKeyPressPrimer` it never opens the microphone: the warm-up only
/// selects the preferred input and builds the live engine's input node, the
/// step `RecordingStartSequencer` runs before capture so a Bluetooth input
/// never builds a node beside an open microphone. A press that does not become
/// a session releases it after the double-tap window, and every warm-up is
/// released after `lifetime` if no start claims it.
///
/// Generic over the warm-up so the lifecycle is testable without audio
/// hardware; the app uses `LiveInputPreparation`.
@MainActor
final class HotKeyInputWarmUp<WarmUp: AnyObject> {
  struct Dependencies {
    /// Whether a press may warm the input now (idle, live-engine route,
    /// microphone authorised, and the key-down primer is not opening it).
    var isEligible: () -> Bool
    /// Whether a released press may still become a session through a double
    /// tap, so the warm-up must outlive the release.
    var keepsAliveForDoubleTap: () -> Bool
    var doubleTapWindow: () -> TimeInterval
    /// Upper bound on how long an unclaimed warm-up is kept.
    var lifetime: () -> TimeInterval
    /// Starts a warm-up. Must return at once; the work runs in the background.
    var begin: () -> WarmUp
    /// Releases an unclaimed warm-up and everything it holds.
    var release: (WarmUp) -> Void
    var schedule: (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> HotKeyPressPrimerTimer
  }

  /// Extra time after the double-tap window before a released press is
  /// dropped, so the gesture recogniser always decides first.
  static var doubleTapGrace: TimeInterval { 0.15 }

  /// How long a warm-up lives without a start, unless the double-tap window
  /// needs longer.
  static var defaultLifetime: TimeInterval { 2 }

  private let dependencies: Dependencies
  private(set) var current: WarmUp?
  private var lastReleaseUptime: TimeInterval?
  private var dropTimer: HotKeyPressPrimerTimer?
  private var lifetimeTimer: HotKeyPressPrimerTimer?

  init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  var isActive: Bool { current != nil }

  func pressBegan(at uptime: TimeInterval) {
    let continuesSequence = dependencies.keepsAliveForDoubleTap()
      && lastReleaseUptime.map { uptime >= $0 && uptime - $0 <= dependencies.doubleTapWindow() } == true
    lastReleaseUptime = nil
    dropTimer?.cancel()
    dropTimer = nil
    if current != nil {
      // The second press of a double tap reuses the first press's warm-up.
      if continuesSequence { return }
      drop()
    }
    guard dependencies.isEligible() else { return }
    let warmUp = dependencies.begin()
    current = warmUp
    lifetimeTimer = dependencies.schedule(dependencies.lifetime()) { [weak self, weak warmUp] in
      guard let self, let warmUp else { return }
      self.drop(ifCurrent: warmUp)
    }
  }

  func pressEnded(at uptime: TimeInterval) {
    lastReleaseUptime = uptime
    guard let warmUp = current else { return }
    guard dependencies.keepsAliveForDoubleTap() else {
      drop()
      return
    }
    dropTimer?.cancel()
    let delay = dependencies.doubleTapWindow() + Self.doubleTapGrace
    dropTimer = dependencies.schedule(delay) { [weak self, weak warmUp] in
      guard let self, let warmUp else { return }
      self.drop(ifCurrent: warmUp)
    }
  }

  /// Hands the warm-up to a starting session, which then owns its release.
  /// Nil when no warm-up is running.
  func claim() -> WarmUp? {
    cancelTimers()
    defer { current = nil }
    return current
  }

  /// Releases an unclaimed warm-up now: hotkey reset, settings change or
  /// shutdown.
  func cancel() {
    drop()
    lastReleaseUptime = nil
  }

  private func drop(ifCurrent expected: WarmUp? = nil) {
    guard let warmUp = current else { return }
    if let expected, expected !== warmUp { return }
    current = nil
    cancelTimers()
    dependencies.release(warmUp)
  }

  private func cancelTimers() {
    dropTimer?.cancel()
    dropTimer = nil
    lifetimeTimer?.cancel()
    lifetimeTimer = nil
  }
}
