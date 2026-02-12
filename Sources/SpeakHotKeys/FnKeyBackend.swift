import AppKit
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

  private let log = Logger(subsystem: "com.justspeaktoit.hotkeys", category: "FnKeyBackend")
  private let functionKeyCode: CGKeyCode = 63
  private let fnAllowedFlags: CGEventFlags = [.maskSecondaryFn, .maskNonCoalesced]

  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var eventTap: CFMachPort?
  private var eventTapRunLoopSource: CFRunLoopSource?
  private var fnIsPressed = false

  func start() {
    guard globalMonitor == nil else { return }

    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) {
      [weak self] event in
      self?.handleNSEvent(event: event)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) {
      [weak self] event in
      self?.handleNSEvent(event: event)
      return event
    }

    startEventTap()
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
    fnIsPressed = false
  }

  nonisolated deinit {
    // Cleanup resources if stop() wasn't called
    // Note: NSEvent.removeMonitor and CGEvent tap cleanup are safe to call from any thread
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

  private func startEventTap() {
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
      return
    }

    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    eventTapRunLoopSource = source
    if let source {
      CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
    CGEvent.tapEnable(tap: tap, enable: true)
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
    default:
      break
    }
    return Unmanaged.passUnretained(event)
  }

  private func updateFnState(isDown: Bool, source: String) {
    guard isDown != fnIsPressed else { return }
    fnIsPressed = isDown
    if isDown {
      onKeyDown?(source)
    } else {
      onKeyUp?(source)
    }
  }
}
