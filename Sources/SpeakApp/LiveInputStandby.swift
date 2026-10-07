import Foundation

/// One idle engine whose input node is already built, kept for the next
/// hotkey press.
///
/// Building an input node costs ~100–300 ms, and about three seconds while
/// another app holds the microphone open. Starting an engine whose input node
/// already exists takes ~50 ms. The key-down primer (`PrimedLiveInput`)
/// therefore starts this engine instead of building one. An engine with a built
/// but unstarted input node does not open the microphone.
///
/// The engine is only handed out for the input device it was built against.
final class LiveInputStandby<Engine: AnyObject>: @unchecked Sendable {
  typealias InputDeviceID = UInt32

  private let lock = NSLock()
  private let makeEngine: () -> Engine
  private let currentInputDeviceID: () -> InputDeviceID?
  private var stocked: (engine: Engine, inputDeviceID: InputDeviceID)?

  /// - Parameter makeEngine: builds an engine *and* its input node.
  init(makeEngine: @escaping () -> Engine, currentInputDeviceID: @escaping () -> InputDeviceID?) {
    self.makeEngine = makeEngine
    self.currentInputDeviceID = currentInputDeviceID
  }

  /// The standby engine when it was built for `inputDeviceID`. A standby built
  /// for another device is dropped: it can never be used again.
  func take(matching inputDeviceID: InputDeviceID) -> Engine? {
    lock.lock()
    defer { lock.unlock() }
    let entry = stocked
    stocked = nil
    return entry?.inputDeviceID == inputDeviceID ? entry?.engine : nil
  }

  /// Builds an engine with its input node now. Blocks for the build.
  func buildEngine() -> Engine {
    makeEngine()
  }

  /// Keeps a stopped engine, whose input node is built, for the next press.
  func stock(_ engine: Engine, inputDeviceID: InputDeviceID) {
    lock.lock()
    defer { lock.unlock() }
    stocked = (engine, inputDeviceID)
  }

  /// Builds a standby for the current input device unless one already
  /// matches it. Blocks for the build; call off the main thread, and only
  /// while nothing holds the microphone open.
  func refill() {
    guard let deviceID = currentInputDeviceID() else { return }
    lock.lock()
    let isCurrent = stocked?.inputDeviceID == deviceID
    lock.unlock()
    guard !isCurrent else { return }
    let engine = makeEngine()
    // The default input can change during a slow build; such an engine would
    // never match the next press.
    guard currentInputDeviceID() == deviceID else { return }
    stock(engine, inputDeviceID: deviceID)
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    stocked = nil
  }

  var stockedInputDeviceID: InputDeviceID? {
    lock.lock()
    defer { lock.unlock() }
    return stocked?.inputDeviceID
  }
}
