#if os(macOS)
import Foundation
import os.log

/// Converts raw keyDown/keyUp events into gestures (hold, tap, double-tap).
///
/// Feed it `keyDown()` and `keyUp()` calls; it emits `HotKeyGesture` values
/// via the `onGesture` callback. Timing is configurable via `configuration`.
@MainActor
public final class GestureDetector {
  public var configuration: HotKeyConfiguration
  public var onGesture: ((HotKeyEvent) -> Void)?

  private let log = Logger(subsystem: "com.justspeaktoit.hotkeys", category: "GestureDetector")

  private var isKeyDown = false
  private var holdFired = false
  private var lastReleaseUptime: TimeInterval = 0
  private var lastDoubleTapFireTime: TimeInterval = 0
  private var doubleTapCooldownDeadline: TimeInterval = 0

  private var holdTimer: DispatchSourceTimer?
  private var pendingSingleTapWorkItem: DispatchWorkItem?

  public init(configuration: HotKeyConfiguration = HotKeyConfiguration()) {
    self.configuration = configuration
  }

  /// Call when the monitored key is pressed down.
  public func keyDown(source: String = "") {
    guard !isKeyDown else { return }
    log.debug("Key down via \(source)")
    isKeyDown = true
    holdFired = false
    pendingSingleTapWorkItem?.cancel()
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
      fire(.holdEnd, source: source)
      lastReleaseUptime = now
      return
    }

    let elapsed = now - lastReleaseUptime
    if elapsed <= configuration.doubleTapWindow {
      pendingSingleTapWorkItem?.cancel()
      pendingSingleTapWorkItem = nil
      fire(.doubleTap, source: source)
      doubleTapCooldownDeadline = now + min(configuration.doubleTapWindow, 0.25)
      lastReleaseUptime = now
      return
    }

    if now < doubleTapCooldownDeadline {
      lastReleaseUptime = now
      return
    }

    let workItem = DispatchWorkItem { [weak self] in
      self?.fire(.singleTap, source: source)
    }
    pendingSingleTapWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + configuration.doubleTapWindow) {
      [weak workItem] in
      guard let workItem, !workItem.isCancelled else { return }
      workItem.perform()
    }
    lastReleaseUptime = now
  }

  /// Reset all state (e.g. when switching hotkey mode).
  public func reset() {
    holdTimer?.cancel()
    holdTimer = nil
    pendingSingleTapWorkItem?.cancel()
    pendingSingleTapWorkItem = nil
    isKeyDown = false
    holdFired = false
    lastReleaseUptime = 0
    lastDoubleTapFireTime = 0
    doubleTapCooldownDeadline = 0
  }

  // MARK: - Private

  private func scheduleHoldTimer(source: String) {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    timer.schedule(deadline: .now() + configuration.holdThreshold)
    timer.setEventHandler { [weak self] in
      guard let self, self.isKeyDown, !self.holdFired else { return }
      self.holdFired = true
      self.fire(.holdStart, source: source)
    }
    holdTimer = timer
    timer.resume()
  }

  private func fire(_ gesture: HotKeyGesture, source: String) {
    if gesture == .doubleTap {
      let now = ProcessInfo.processInfo.systemUptime
      let minimumGap = max(0.2, configuration.doubleTapWindow * 0.5)
      if now - lastDoubleTapFireTime < minimumGap {
        log.debug("Ignoring duplicate double tap")
        return
      }
      lastDoubleTapFireTime = now
    }

    log.debug("Firing gesture: \(gesture.rawValue)")
    let event = HotKeyEvent(gesture: gesture, source: source)
    onGesture?(event)
  }
}

#endif
