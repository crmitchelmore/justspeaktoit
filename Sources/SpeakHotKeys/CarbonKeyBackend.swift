#if os(macOS)
import AppKit
import Carbon
import Foundation
import os.log

/// Detects arbitrary key combinations using the Carbon `RegisterEventHotKey` API.
///
/// Handles both `kEventHotKeyPressed` and `kEventHotKeyReleased` to support
/// hold gesture detection. Works globally even when app is not focused.
@MainActor
final class CarbonKeyBackend {
  var onKeyDown: ((String) -> Void)?
  var onKeyUp: ((String) -> Void)?

  private let log = Logger(subsystem: "com.justspeaktoit.hotkeys", category: "CarbonKeyBackend")
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  private var currentKeyCode: UInt16 = 0
  private var currentModifiers: HotKey.ModifierSet = []

  /// Unique Carbon hotkey signature for SpeakHotKeys.
  private let hotKeySignature: UInt32 = 0x5348_4B00  // "SHK\0"
  private let hotKeyID: UInt32 = 1

  func start(keyCode: UInt16, modifiers: HotKey.ModifierSet) {
    stop()
    currentKeyCode = keyCode
    currentModifiers = modifiers

    installEventHandler()
    registerHotKey(keyCode: keyCode, modifiers: modifiers)
  }

  func stop() {
    unregisterHotKey()
    removeEventHandler()
  }

  deinit {
    if let ref = hotKeyRef {
      UnregisterEventHotKey(ref)
    }
    if let handler = eventHandler {
      RemoveEventHandler(handler)
    }
  }

  // MARK: - Carbon Event Handler

  private func installEventHandler() {
    guard eventHandler == nil else { return }

    var eventTypes = [
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]

    let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

    let status = InstallEventHandler(
      GetEventDispatcherTarget(),
      { _, event, userData -> OSStatus in
        guard let userData, let event else { return OSStatus(eventNotHandledErr) }
        let backend = Unmanaged<CarbonKeyBackend>.fromOpaque(userData).takeUnretainedValue()
        return backend.handleCarbonEvent(event)
      },
      eventTypes.count,
      &eventTypes,
      selfPtr,
      &eventHandler
    )

    if status != noErr {
      log.error("Failed to install Carbon event handler: \(status)")
    }
  }

  private func removeEventHandler() {
    if let handler = eventHandler {
      RemoveEventHandler(handler)
      eventHandler = nil
    }
  }

  private func registerHotKey(keyCode: UInt16, modifiers: HotKey.ModifierSet) {
    let hotKeyIDSpec = EventHotKeyID(signature: hotKeySignature, id: hotKeyID)
    let status = RegisterEventHotKey(
      UInt32(keyCode),
      modifiers.carbonFlags,
      hotKeyIDSpec,
      GetEventDispatcherTarget(),
      0,
      &hotKeyRef
    )

    if status != noErr {
      log.error("Failed to register Carbon hotkey (keyCode=\(keyCode)): \(status)")
    } else {
      log.info("Registered Carbon hotkey: keyCode=\(keyCode), modifiers=\(modifiers.rawValue)")
    }
  }

  private func unregisterHotKey() {
    if let ref = hotKeyRef {
      UnregisterEventHotKey(ref)
      hotKeyRef = nil
    }
  }

  private nonisolated func handleCarbonEvent(_ event: EventRef) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
      event,
      UInt32(kEventParamDirectObject),
      UInt32(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      nil,
      &hotKeyID
    )

    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    guard hotKeyID.signature == hotKeySignature, hotKeyID.id == self.hotKeyID else {
      return OSStatus(eventNotHandledErr)
    }

    let eventKind = GetEventKind(event)
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      switch Int(eventKind) {
      case kEventHotKeyPressed:
        self.onKeyDown?("carbon")
      case kEventHotKeyReleased:
        self.onKeyUp?("carbon")
      default:
        break
      }
    }

    return noErr
  }
}

#endif
