#if os(macOS)
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os.log

/// Detects Fn/Globe key presses using CGEvent tap with NSEvent fallback.
///
/// Calls `onKeyDown` / `onKeyUp` when the Fn key state changes.
/// Uses a layered approach:
/// 1. CGEvent tap (primary) — most reliable for Fn detection
/// 2. NSEvent monitors (fallback) — catches events when tap is unavailable
/// 3. Hardware state probing — reconciles missed edges
@MainActor
final class FnKeyBackend {
  var onKeyDown: ((String) -> Void)?
  var onKeyUp: ((String) -> Void)?

  private let log = Logger(subsystem: HotKeyLogging.subsystem, category: "FnKeyBackend")
  private let functionKeyCode: CGKeyCode = 63
  private let fnAllowedFlags: CGEventFlags = [.maskSecondaryFn, .maskNonCoalesced]

  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var eventTap: CFMachPort?
  private var eventTapRunLoopSource: CFRunLoopSource?
  private var hardwareStateTimer: Timer?
  private var hardwareStateInterval: TimeInterval?
  private var hardwareStatePollingEnabled = false
  private var tapDisabledAtUptime: TimeInterval?
  private var fnIsPressed = false

  @discardableResult
  func start() -> Bool {
    guard globalMonitor == nil else { return true }

    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) {
      [weak self] event in
      self?.handleNSEvent(event: event)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) {
      [weak self] event in
      self?.handleNSEvent(event: event)
      return event
    }

    let eventTapStarted = startEventTap()
    startHardwareStatePolling()
    return eventTapStarted || globalMonitor != nil
  }

  func stop() {
    if let globalMonitor {
      NSEvent.removeMonitor(globalMonitor)
      self.globalMonitor = nil
    }
    if let localMonitor {
      NSEvent.removeMonitor(localMonitor)
      self.localMonitor = nil
    }
    stopEventTap()
    hardwareStateTimer?.invalidate()
    hardwareStateTimer = nil
    hardwareStateInterval = nil
    hardwareStatePollingEnabled = false
    tapDisabledAtUptime = nil
    fnIsPressed = false
  }

  deinit {
    if let monitor = globalMonitor {
      NSEvent.removeMonitor(monitor)
    }
    if let monitor = localMonitor {
      NSEvent.removeMonitor(monitor)
    }
    if let source = eventTapRunLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    if let tap = eventTap {
      CGEvent.tapEnable(tap: tap, enable: false)
    }
    hardwareStateTimer?.invalidate()
  }

  // MARK: - NSEvent Handling (Fallback)

  private func handleNSEvent(event: NSEvent) {
    if event.type == .flagsChanged {
      // Rely on CGEvent tap when available
      guard eventTap == nil else { return }
    }
    switch event.type {
    case .flagsChanged:
      guard CGKeyCode(event.keyCode) == functionKeyCode else { return }
      let isFnDown = event.modifierFlags.contains(.function)
      updateFnState(isDown: isFnDown, source: "flagsFallback")
    case .keyDown:
      guard CGKeyCode(event.keyCode) == functionKeyCode else { return }
      updateFnState(isDown: true, source: "keyDown")
    case .keyUp:
      guard CGKeyCode(event.keyCode) == functionKeyCode else { return }
      updateFnState(isDown: false, source: "keyUp")
    default:
      break
    }
  }

  // MARK: - CGEvent Tap (Primary)

  private func startEventTap() -> Bool {
    stopEventTap()
    let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: { _, type, cgEvent, refcon in
          guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
          let backend = Unmanaged<FnKeyBackend>.fromOpaque(refcon).takeUnretainedValue()
          return backend.handleCGEvent(type: type, event: cgEvent)
        },
        userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
      )
    else {
      log.error("Failed to start CGEvent tap; using NSEvent fallback")
      return false
    }

    guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
      CGEvent.tapEnable(tap: tap, enable: false)
      log.error("Failed to create the CGEvent tap run-loop source; using NSEvent fallback")
      return false
    }

    eventTap = tap
    eventTapRunLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
  }

  private func stopEventTap() {
    if let source = eventTapRunLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    eventTapRunLoopSource = nil
    if let tap = eventTap {
      CGEvent.tapEnable(tap: tap, enable: false)
    }
    eventTap = nil
  }

  /// Terminal and other secure-input clients can temporarily starve event-tap
  /// and global-monitor callbacks. Poll the Fn hardware state independently so
  /// the configured shortcut still receives balanced down/up edges there.
  ///
  /// The cadence is adaptive (see `FnKeyPollingPolicy`): a coalescable 20 Hz
  /// baseline while nothing suggests the tap is unreliable — fast enough that a
  /// short tap made just as secure input engages is still seen — and 50 Hz
  /// while Fn is held, while secure input is enabled, or just after the tap was
  /// disabled.
  private func startHardwareStatePolling() {
    hardwareStatePollingEnabled = true
    hardwareStateInterval = nil
    updateHardwareStatePollingCadence()
  }

  /// Recreates the poll timer when the desired cadence changes. Cheap and
  /// idempotent otherwise, so callers can invoke it on every state change.
  ///
  /// `secureInput` is a parameter so a caller that already sampled
  /// `IsSecureEventInputEnabled()` earlier in the same tick can reuse that
  /// reading instead of taking a second, later one.
  private func updateHardwareStatePollingCadence(
    secureInput: Bool = IsSecureEventInputEnabled()
  ) {
    guard hardwareStatePollingEnabled else { return }
    let desired = desiredHardwareStateInterval(secureInput: secureInput)
    guard desired != hardwareStateInterval else { return }

    hardwareStateTimer?.invalidate()
    let timer = Timer(timeInterval: desired, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.reconcileHardwareState()
      }
    }
    timer.tolerance = FnKeyPollingPolicy.tolerance(for: desired)
    hardwareStateTimer = timer
    hardwareStateInterval = desired
    RunLoop.main.add(timer, forMode: .common)
  }

  private func desiredHardwareStateInterval(secureInput: Bool) -> TimeInterval {
    let recentTapRecovery = FnKeyPollingPolicy.isWithinTapRecoveryWindow(
      disabledAtUptime: tapDisabledAtUptime,
      nowUptime: ProcessInfo.processInfo.systemUptime
    )
    if !recentTapRecovery {
      tapDisabledAtUptime = nil
    }
    return FnKeyPollingPolicy.interval(
      isPressed: fnIsPressed,
      secureInput: secureInput,
      recentTapRecovery: recentTapRecovery
    )
  }

  /// The hardware poll's sole signal. Kept as a pure function so the rule
  /// "the secondary-fn flag is never consulted" is pinned by a test.
  nonisolated static func isFnKeyDown(keyState: Bool) -> Bool {
    keyState
  }

  private func reconcileHardwareState() {
    // Sampled before the probe, not after it: a password field that just took
    // secure input has to escalate *this* tick, otherwise the escalation only
    // starts a full baseline interval after the condition it exists for.
    let secureInput = IsSecureEventInputEnabled()
    // Only key code 63 counts. `.maskSecondaryFn` is NX_SECONDARYFNMASK, the
    // same bit as NSEvent.ModifierFlags.function, which macOS sets for *any*
    // function key: arrows, F-keys, Home/End/PageUp/PageDown. Trusting it made
    // two quick arrow presses look like a double-tap of Fn (issue #863). The
    // event-tap path below already requires key code 63; the poll must too.
    let keyDown = Self.isFnKeyDown(
      keyState: CGEventSource.keyState(.hidSystemState, key: functionKeyCode)
    )
    updateFnState(isDown: keyDown, source: "hardwarePoll")
    // Re-evaluate every tick so secure-input toggles and expiring tap-recovery
    // windows change the cadence without needing a separate timer.
    updateHardwareStatePollingCadence(secureInput: secureInput)
  }

  private func handleCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    switch type {
    case .flagsChanged:
      let rawKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
      let fnBitInFlags = event.flags.contains(.maskSecondaryFn)
      let hardwareFnDown = CGEventSource.keyState(.hidSystemState, key: functionKeyCode)
      let isFnKeyCode: Bool
      if rawKeyCode == -1 {
        isFnKeyCode = true
      } else if rawKeyCode >= 0 && rawKeyCode <= Int64(UInt16.max) {
        isFnKeyCode = CGKeyCode(UInt16(rawKeyCode)) == functionKeyCode
      } else {
        isFnKeyCode = false
      }
      let hasOnlyAllowedFlags = event.flags.subtracting(fnAllowedFlags).isEmpty
      if isFnKeyCode && hasOnlyAllowedFlags {
        let inferredState = fnBitInFlags || hardwareFnDown
        updateFnState(isDown: inferredState, source: "cgFlags")
      } else {
        if fnIsPressed != hardwareFnDown {
          updateFnState(isDown: hardwareFnDown, source: "hardwareProbe")
        } else if !fnBitInFlags && fnIsPressed {
          updateFnState(isDown: false, source: "cgFlagsReset")
        }
      }
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      if let tap = eventTap {
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      // Edges may have been dropped while the tap was off; poll fast for a
      // short window so any missed down/up is reconciled quickly.
      tapDisabledAtUptime = ProcessInfo.processInfo.systemUptime
      updateHardwareStatePollingCadence()
    default:
      break
    }
    return Unmanaged.passUnretained(event)
  }

  private func updateFnState(isDown: Bool, source: String) {
    guard isDown != fnIsPressed else { return }
    fnIsPressed = isDown
    // A press escalates the poll so a missed key-up cannot strand a hold;
    // a release drops it back to the coalescable baseline.
    updateHardwareStatePollingCadence()
    if isDown {
      onKeyDown?(source)
    } else {
      onKeyUp?(source)
    }
  }
}

#endif
