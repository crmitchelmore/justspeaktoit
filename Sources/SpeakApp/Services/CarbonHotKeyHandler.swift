import Carbon
import Foundation
import os

/// The application-wide Carbon hot-key event handler and the `userData` it
/// hands back to Carbon.
///
/// Carbon receives this object unretained, so it must never call back after
/// the object goes away. Retirement is synchronous: `remove()` (and `deinit`)
/// first closes the gate `deliver` checks, then removes the Carbon handler, so
/// an event that races teardown is reported unhandled instead of reaching a
/// deallocating owner.
final class CarbonHotKeyHandler: @unchecked Sendable {
  /// Signature stamped on every hot key this app registers.
  static let signature: OSType = 0x5350_4B00

  private let onHotKey: @Sendable (UInt32) -> Void
  private let isActive = OSAllocatedUnfairLock(initialState: true)
  private var handlerRef: EventHandlerRef?

  /// Creates the gate without installing it; see `install(on:)`.
  init(onHotKey: @escaping @Sendable (UInt32) -> Void) {
    self.onHotKey = onHotKey
  }

  /// Installs the handler on `target`. Returns the Carbon status; on failure
  /// the handler is inactive.
  @discardableResult
  func install(on target: EventTargetRef = GetApplicationEventTarget()) -> OSStatus {
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let status = InstallEventHandler(
      target,
      { _, event, userData -> OSStatus in
        guard let userData, let event, let hotKeyID = CarbonHotKeyHandler.hotKeyID(in: event) else {
          return OSStatus(eventNotHandledErr)
        }
        let handler = Unmanaged<CarbonHotKeyHandler>.fromOpaque(userData).takeUnretainedValue()
        return handler.deliver(hotKeyID: hotKeyID) ? noErr : OSStatus(eventNotHandledErr)
      },
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &handlerRef
    )
    if status != noErr {
      handlerRef = nil
      isActive.withLock { $0 = false }
    }
    return status
  }

  var isInstalled: Bool {
    isActive.withLock { $0 }
  }

  /// Passes a hot-key press on while the handler is active. Returns false
  /// once it has been removed.
  func deliver(hotKeyID: UInt32) -> Bool {
    guard isActive.withLock({ $0 }) else { return false }
    onHotKey(hotKeyID)
    return true
  }

  /// Stops delivery, then removes the Carbon handler. Idempotent.
  func remove() {
    isActive.withLock { $0 = false }
    guard let handlerRef else { return }
    self.handlerRef = nil
    RemoveEventHandler(handlerRef)
  }

  deinit {
    remove()
  }

  /// The id of this app's hot key carried by `event`, or nil for anything else.
  static func hotKeyID(in event: EventRef) -> UInt32? {
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
    guard status == noErr, hotKeyID.signature == signature else { return nil }
    return hotKeyID.id
  }
}
