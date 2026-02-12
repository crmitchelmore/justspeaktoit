#if os(macOS)
import AppKit
import Foundation
import os.log

/// The main hotkey engine — manages backends and gesture detection.
///
/// Supports two modes:
/// - `.fnKey`: Uses CGEvent tap + NSEvent fallback (proven Fn detection)
/// - `.custom(keyCode:modifiers:)`: Uses Carbon `RegisterEventHotKey`
///
/// Both modes feed into the same `GestureDetector`, so hold/tap/double-tap
/// gestures work identically regardless of which key is configured.
///
/// Usage:
/// ```swift
/// let engine = HotKeyEngine()
/// let token = engine.register(gesture: .holdStart) { event in
///     // start recording
/// }
/// engine.start(for: .fnKey)
/// ```
@MainActor
public final class HotKeyEngine: ObservableObject {
  /// The currently active hotkey.
  @Published public private(set) var activeHotKey: HotKey?

  /// Whether the engine is currently monitoring.
  @Published public private(set) var isMonitoring = false

  /// Whether the key is currently held down.
  @Published public private(set) var isKeyDown = false

  public let gestureDetector: GestureDetector

  private let log = Logger(subsystem: "com.justspeaktoit.hotkeys", category: "HotKeyEngine")
  private let fnBackend = FnKeyBackend()
  private let carbonBackend = CarbonKeyBackend()
  private var listeners: [HotKeyGesture: [UUID: (HotKeyEvent) -> Void]] = [:]

  public init(configuration: HotKeyConfiguration = HotKeyConfiguration()) {
    self.gestureDetector = GestureDetector(configuration: configuration)

    gestureDetector.onGesture = { [weak self] event in
      self?.fireListeners(event: event)
    }

    fnBackend.onKeyDown = { [weak self] source in
      self?.isKeyDown = true
      self?.gestureDetector.keyDown(source: source)
    }
    fnBackend.onKeyUp = { [weak self] source in
      self?.isKeyDown = false
      self?.gestureDetector.keyUp(source: source)
    }

    carbonBackend.onKeyDown = { [weak self] source in
      self?.isKeyDown = true
      self?.gestureDetector.keyDown(source: source)
    }
    carbonBackend.onKeyUp = { [weak self] source in
      self?.isKeyDown = false
      self?.gestureDetector.keyUp(source: source)
    }
  }

  // MARK: - Start / Stop

  /// Start monitoring for the given hotkey.
  public func start(for hotKey: HotKey) {
    stop()
    activeHotKey = hotKey
    isMonitoring = true

    switch hotKey {
    case .fnKey:
      log.info("Starting Fn key monitoring")
      fnBackend.start()
    case .custom(let keyCode, let modifiers):
      log.info("Starting Carbon monitoring: keyCode=\(keyCode), modifiers=\(modifiers.rawValue)")
      carbonBackend.start(keyCode: keyCode, modifiers: modifiers)
    }
  }

  /// Stop all monitoring.
  public func stop() {
    fnBackend.stop()
    carbonBackend.stop()
    gestureDetector.reset()
    isMonitoring = false
    isKeyDown = false
    activeHotKey = nil
  }

  /// Update timing configuration.
  public func updateConfiguration(_ configuration: HotKeyConfiguration) {
    gestureDetector.configuration = configuration
  }

  // MARK: - Listener Registration

  /// Register a handler for a specific gesture. Returns a token for unregistration.
  @discardableResult
  public func register(gesture: HotKeyGesture, handler: @escaping (HotKeyEvent) -> Void) -> HotKeyListenerToken {
    let id = UUID()
    var handlers = listeners[gesture, default: [:]]
    handlers[id] = handler
    listeners[gesture] = handlers
    return HotKeyListenerToken(id: id, gesture: gesture)
  }

  /// Convenience: register with a simple closure (no event parameter).
  @discardableResult
  public func register(gesture: HotKeyGesture, handler: @escaping () -> Void) -> HotKeyListenerToken {
    register(gesture: gesture) { _ in handler() }
  }

  /// Unregister a previously registered handler.
  public func unregister(_ token: HotKeyListenerToken) {
    listeners[token.gesture]?[token.id] = nil
  }

  // MARK: - Private

  private func fireListeners(event: HotKeyEvent) {
    listeners[event.gesture]?.values.forEach { handler in
      handler(event)
    }
  }
}

#endif
