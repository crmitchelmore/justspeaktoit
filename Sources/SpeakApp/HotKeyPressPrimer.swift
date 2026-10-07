import Foundation

/// Cancels a scheduled primer action. Cancelling twice, or after the action
/// ran, does nothing.
struct HotKeyPressPrimerTimer {
  let cancel: () -> Void
}

/// Opens the microphone on hotkey key-down so device warm-up overlaps the
/// hold threshold, and closes it again when the press does not become a
/// session.
///
/// Generic over the capture so the state machine is testable without audio
/// hardware; the app uses `PrimedLiveInput`. The primer only opens and closes
/// captures: it never records history, plays cues, shows UI or contacts a
/// provider, so a cancelled press leaves no trace beyond the brief microphone
/// use.
///
/// Every open and close runs through one serial chain, so a press that
/// follows a cancelled one starts only after the earlier capture has stopped.
@MainActor
final class HotKeyPressPrimer<Capture: AnyObject> {
  struct Dependencies {
    /// Whether a press may open the microphone now (setting on, idle, mic
    /// permission granted…). Checked on key-down only.
    var isEligible: () -> Bool
    /// Whether a released press may still become a session through a double
    /// tap, so the capture must outlive the release.
    var keepsAliveForDoubleTap: () -> Bool
    var doubleTapWindow: () -> TimeInterval
    /// Upper bound on how long a press keeps the microphone open without a
    /// session claiming it.
    var safetyTimeout: () -> TimeInterval
    var open: (_ keyDownUptime: TimeInterval) async -> Capture?
    var close: (Capture) async -> Void
    var schedule: (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> HotKeyPressPrimerTimer
  }

  private enum Phase {
    case idle
    case opening(generation: UInt64, task: Task<Capture?, Never>)
    case open(generation: UInt64, capture: Capture)
    /// A session claimed the press while the capture was still opening.
    case reserved(generation: UInt64)
  }

  /// Extra time after the double-tap window before a released press is
  /// dropped, so the gesture recogniser always decides first.
  static var doubleTapGrace: TimeInterval { 0.15 }

  private let dependencies: Dependencies
  private var phase = Phase.idle
  private var generation: UInt64 = 0
  private var tail: Task<Void, Never>?
  private var dropTimer: HotKeyPressPrimerTimer?
  private var safetyTimer: HotKeyPressPrimerTimer?
  private var lastReleaseUptime: TimeInterval?

  /// Key-down of the first press of the current press sequence (a double
  /// tap's first press), recorded whether or not the primer opened anything.
  private(set) var sequenceKeyDownUptime: TimeInterval?

  init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  var isActive: Bool {
    if case .idle = phase { return false }
    return true
  }

  /// Completes once every queued open and close has run.
  func settle() async {
    await tail?.value
  }

  func pressBegan(at uptime: TimeInterval) {
    if let lastReleaseUptime, uptime - lastReleaseUptime <= dependencies.doubleTapWindow() {
      // Second press of a possible double tap: same sequence.
    } else {
      sequenceKeyDownUptime = uptime
    }
    dropTimer?.cancel()
    dropTimer = nil
    if isActive {
      // Second press of a double tap: keep the capture already opening.
      scheduleSafetyTimeout()
      return
    }
    guard dependencies.isEligible() else { return }
    generation &+= 1
    let current = generation
    let keyDown = sequenceKeyDownUptime ?? uptime
    let previous = tail
    let open = dependencies.open
    let close = dependencies.close
    let task = Task { @MainActor [weak self] () -> Capture? in
      await previous?.value
      guard let self, self.isCurrentOpening(current) else { return nil }
      guard let capture = await open(keyDown) else {
        self.finishOpening(current)
        return nil
      }
      switch self.phase {
      case .opening(let generation, _) where generation == current:
        self.phase = .open(generation: current, capture: capture)
        return nil
      case .reserved(let generation) where generation == current:
        self.phase = .idle
        return capture
      default:
        await close(capture)
        return nil
      }
    }
    phase = .opening(generation: current, task: task)
    tail = Task { _ = await task.value }
    scheduleSafetyTimeout()
  }

  func pressEnded(at uptime: TimeInterval) {
    lastReleaseUptime = uptime
    guard isActive else { return }
    guard dependencies.keepsAliveForDoubleTap() else {
      drop()
      return
    }
    let current = generation
    dropTimer?.cancel()
    dropTimer = dependencies.schedule(dependencies.doubleTapWindow() + Self.doubleTapGrace) { [weak self] in
      self?.drop(ifGeneration: current)
    }
  }

  /// Closes an unclaimed capture now: hotkey reset, a press that cannot
  /// become a session, or shutdown. A claimed (reserved) capture is the
  /// session's to close.
  func cancel() {
    drop()
  }

  /// Claims the press's capture for a starting session. Nil when the press
  /// opened nothing. The task yields nil when the open fails.
  func reserve() -> Task<Capture?, Never>? {
    cancelTimers()
    switch phase {
    case .idle, .reserved:
      return nil
    case .open(_, let capture):
      phase = .idle
      return Task { capture }
    case .opening(let generation, let task):
      phase = .reserved(generation: generation)
      return task
    }
  }

  /// Closes a capture a session claimed but never used, in order with every
  /// other open and close.
  func enqueueClose(_ capture: Capture) {
    let previous = tail
    let close = dependencies.close
    tail = Task { @MainActor in
      await previous?.value
      await close(capture)
    }
  }

  private func drop(ifGeneration expected: UInt64? = nil) {
    if let expected, expected != generation { return }
    switch phase {
    case .idle, .reserved:
      return
    case .opening:
      // The open task sees it is no longer current and closes its capture.
      phase = .idle
    case .open(_, let capture):
      phase = .idle
      enqueueClose(capture)
    }
    cancelTimers()
  }

  private func isCurrentOpening(_ expected: UInt64) -> Bool {
    switch phase {
    case .opening(let generation, _), .reserved(let generation):
      return generation == expected
    default:
      return false
    }
  }

  private func finishOpening(_ expected: UInt64) {
    if isCurrentOpening(expected) {
      phase = .idle
      cancelTimers()
    }
  }

  private func scheduleSafetyTimeout() {
    let current = generation
    safetyTimer?.cancel()
    safetyTimer = dependencies.schedule(dependencies.safetyTimeout()) { [weak self] in
      self?.drop(ifGeneration: current)
    }
  }

  private func cancelTimers() {
    dropTimer?.cancel()
    dropTimer = nil
    safetyTimer?.cancel()
    safetyTimer = nil
  }
}
