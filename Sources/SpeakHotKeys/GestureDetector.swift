#if os(macOS)
import Foundation
import os.log

/// Converts raw keyDown/keyUp events into gestures (hold, tap, double-tap, triple-tap).
///
/// Feed it `keyDown()` and `keyUp()` calls; it emits `HotKeyGesture` values
/// via the `onGesture` callback. Timing is configurable via `configuration`.
@MainActor
public final class GestureDetector {
  public var configuration: HotKeyConfiguration
  public var onGesture: ((HotKeyEvent) -> Void)?

  private let log = Logger(subsystem: HotKeyLogging.subsystem, category: "GestureDetector")

  private var isKeyDown = false
  private var holdFired = false
  private var tapCount = 0
  private var lastReleaseUptime: TimeInterval = 0
  private var cooldownUntilUptime: TimeInterval = 0

  private var holdTimer: DispatchSourceTimer?
  private var pendingTapWorkItem: DispatchWorkItem?

  public init(configuration: HotKeyConfiguration = HotKeyConfiguration()) {
    self.configuration = configuration
  }

  /// Call when the monitored key is pressed down.
  public func keyDown(source: String = "") {
    guard !isKeyDown else { return }
    guard ProcessInfo.processInfo.systemUptime >= cooldownUntilUptime else {
      log.debug("Ignoring key down during gesture cooldown")
      return
    }
    log.debug("Key down via \(source)")
    isKeyDown = true
    holdFired = false
    scheduleHoldTimer(source: source)
  }

  /// Call when the monitored key is released.
  public func keyUp(source: String = "") {
    guard isKeyDown else { return }
    log.debug("Key up via \(source)")
    isKeyDown = false
    holdTimer?.cancel()
    holdTimer = nil

    let now = ProcessInfo.processInfo.systemUptime
    if holdFired {
      holdFired = false
      resetTapSequence()
      fire(.holdEnd, source: source)
      return
    }

    let elapsed = now - lastReleaseUptime
    tapCount = elapsed <= configuration.doubleTapWindow ? tapCount + 1 : 1
    lastReleaseUptime = now
    pendingTapWorkItem?.cancel()
    pendingTapWorkItem = nil

    if tapCount == 3 {
      resetTapSequence()
      fire(.tripleTap, source: source)
      return
    }

    let pendingCount = tapCount
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.tapCount == pendingCount else { return }
      self.resetTapSequence()
      self.fire(pendingCount == 1 ? .singleTap : .doubleTap, source: source)
    }
    pendingTapWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + configuration.doubleTapWindow) {
      [weak workItem] in
      guard let workItem, !workItem.isCancelled else { return }
      workItem.perform()
    }
  }

  /// Whether a hold is in progress: `holdStart` fired and `holdEnd` is still due.
  public var isHoldInProgress: Bool { holdFired }

  /// Reset all state (e.g. when switching hotkey mode).
  ///
  /// A hold that is in progress ends first with a balanced `holdEnd`. Teardown
  /// removes the monitoring backend, so the matching key-up can no longer arrive.
  /// Without the balanced end, the recording that `holdStart` started keeps the
  /// microphone open until the user stops it by hand.
  public func reset(source: String = "reset") {
    holdTimer?.cancel()
    holdTimer = nil
    pendingTapWorkItem?.cancel()
    pendingTapWorkItem = nil
    let hadHoldInProgress = holdFired
    isKeyDown = false
    holdFired = false
    tapCount = 0
    lastReleaseUptime = 0
    cooldownUntilUptime = 0

    if hadHoldInProgress {
      log.info("Ending an in-progress hold because the detector was reset")
      fire(.holdEnd, source: source)
    }
  }

  // MARK: - Private

  private func scheduleHoldTimer(source: String) {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    timer.schedule(deadline: .now() + configuration.holdThreshold)
    timer.setEventHandler { [weak self] in
      guard let self, self.isKeyDown, !self.holdFired else { return }
      self.holdFired = true
      self.resetTapSequence()
      self.fire(.holdStart, source: source)
    }
    holdTimer = timer
    timer.resume()
  }

  private func resetTapSequence() {
    pendingTapWorkItem?.cancel()
    pendingTapWorkItem = nil
    tapCount = 0
    lastReleaseUptime = 0
  }

  private func fire(_ gesture: HotKeyGesture, source: String) {
    log.debug("Firing gesture: \(gesture.rawValue)")
    if gesture != .holdStart {
      cooldownUntilUptime = ProcessInfo.processInfo.systemUptime + configuration.gestureCooldown
    }
    let event = HotKeyEvent(gesture: gesture, source: source)
    onGesture?(event)
  }
}

#endif
