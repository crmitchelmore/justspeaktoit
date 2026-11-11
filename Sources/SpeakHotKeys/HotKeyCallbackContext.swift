#if os(macOS)
import Foundation
import os

/// The `userData` a C callback registration (a Carbon event handler or a
/// CGEvent tap) carries back to its Swift owner.
///
/// The registration holds a +1 reference for as long as it exists, so the
/// pointer can never dangle; the owner releases it with `release(_:)` only
/// after the registration is gone. The owner itself is held weakly and cut off
/// by `invalidate()` before teardown starts, so a callback that races teardown
/// finds no owner instead of a deallocating one.
final class HotKeyCallbackContext<Owner: AnyObject>: @unchecked Sendable {
  private let state: OSAllocatedUnfairLock<WeakOwner>

  init(owner: Owner) {
    state = OSAllocatedUnfairLock(initialState: WeakOwner(value: owner))
  }

  /// The owner while the registration is live; nil once invalidated or freed.
  var owner: Owner? {
    state.withLock { $0.value }
  }

  /// A retained pointer for the C API. Balance it with `release(_:)` once the
  /// registration has been removed.
  func retainedPointer() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(self).toOpaque()
  }

  /// Stops resolving the owner. Call before removing the registration.
  func invalidate() {
    state.withLock { $0.value = nil }
  }

  /// The context behind a pointer from `retainedPointer()`, without taking
  /// ownership.
  static func context(from pointer: UnsafeMutableRawPointer) -> HotKeyCallbackContext {
    Unmanaged<HotKeyCallbackContext>.fromOpaque(pointer).takeUnretainedValue()
  }

  /// Gives back the registration's reference. Exactly once per pointer.
  static func release(_ pointer: UnsafeMutableRawPointer) {
    Unmanaged<HotKeyCallbackContext>.fromOpaque(pointer).release()
  }

  private struct WeakOwner: @unchecked Sendable {
    weak var value: Owner?
  }
}
#endif
