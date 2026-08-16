#if os(macOS)
import AppKit
import Foundation
import os.log

/// Unified logging subsystem for SpeakHotKeys, matching the host app's bundle
/// identifier so hotkey logs show up under the same `log stream` filter as the
/// rest of the app. (SpeakHotKeys has no SpeakCore dependency, so it cannot use
/// `SpeakLogger` directly.)
enum HotKeyLogging {
  static let subsystem = Bundle.main.bundleIdentifier ?? "com.justspeaktoit"
}

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

  private let log = Logger(subsystem: HotKeyLogging.subsystem, category: "HotKeyEngine")
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
    guard hotKey.isSupportedForGlobalMonitoring else {
      log.error("Refusing unsupported unmodified global hotkey: \(hotKey.displayString)")
      return
    }
    activeHotKey = hotKey
    let didStart: Bool

    switch hotKey {
    case .fnKey:
      log.info("Starting Fn key monitoring")
      didStart = fnBackend.start()
    case .custom(let keyCode, let modifiers):
      log.info("Starting Carbon monitoring: keyCode=\(keyCode), modifiers=\(modifiers.rawValue)")
      didStart = carbonBackend.start(keyCode: keyCode, modifiers: modifiers)
    }
    isMonitoring = didStart
    if !didStart {
      log.error("Failed to start global hotkey backend for \(hotKey.displayString)")
    }
  }

  /// Stop all monitoring.
  ///
  /// A hold that is in progress ends with a balanced `holdEnd`, so listeners
  /// never keep a hold-started recording open after the backend goes away.
  public func stop() {
    fnBackend.stop()
    carbonBackend.stop()
    isMonitoring = false
    isKeyDown = false
    activeHotKey = nil
    gestureDetector.reset(source: "engine stop")
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
