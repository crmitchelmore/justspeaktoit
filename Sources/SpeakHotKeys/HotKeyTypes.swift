#if os(macOS)
// MARK: - Core Types

import AppKit
import Carbon
import Foundation

/// Represents a hotkey binding — either the Fn/Globe key or a custom key combination.
public enum HotKey: Codable, Hashable, Sendable {
  case fnKey
  case custom(keyCode: UInt16, modifiers: ModifierSet)

  /// Modifier flags stored as a Codable, Sendable, Hashable set.
  public struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let command = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let shift = ModifierSet(rawValue: 1 << 2)
    public static let control = ModifierSet(rawValue: 1 << 3)

    public init(from nsFlags: NSEvent.ModifierFlags) {
      var raw: UInt = 0
      if nsFlags.contains(.command) { raw |= ModifierSet.command.rawValue }
      if nsFlags.contains(.option) { raw |= ModifierSet.option.rawValue }
      if nsFlags.contains(.shift) { raw |= ModifierSet.shift.rawValue }
      if nsFlags.contains(.control) { raw |= ModifierSet.control.rawValue }
      self.init(rawValue: raw)
    }

    public var nsEventFlags: NSEvent.ModifierFlags {
      var flags: NSEvent.ModifierFlags = []
      if contains(.command) { flags.insert(.command) }
      if contains(.option) { flags.insert(.option) }
      if contains(.shift) { flags.insert(.shift) }
      if contains(.control) { flags.insert(.control) }
      return flags
    }

    public var carbonFlags: UInt32 {
      var carbon: UInt32 = 0
      if contains(.command) { carbon |= UInt32(cmdKey) }
      if contains(.option) { carbon |= UInt32(optionKey) }
      if contains(.shift) { carbon |= UInt32(shiftKey) }
      if contains(.control) { carbon |= UInt32(controlKey) }
      return carbon
    }
  }

  /// Human-readable display string for the hotkey.
  public var displayString: String {
    switch self {
    case .fnKey:
      return "🌐 Fn"
    case .custom(let keyCode, let modifiers):
      var parts: [String] = []
      if modifiers.contains(.control) { parts.append("⌃") }
      if modifiers.contains(.option) { parts.append("⌥") }
      if modifiers.contains(.shift) { parts.append("⇧") }
      if modifiers.contains(.command) { parts.append("⌘") }
      parts.append(KeyCodeMapping.string(for: keyCode))
      return parts.joined()
    }
  }

  public var isFnKey: Bool {
    if case .fnKey = self { return true }
    return false
  }
}

/// Gesture types emitted by the hotkey engine.
public enum HotKeyGesture: String, CaseIterable, Identifiable, Sendable {
  case holdStart
  case holdEnd
  case singleTap
  case doubleTap

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .holdStart: return "Hold Start"
    case .holdEnd: return "Hold End"
    case .singleTap: return "Single Tap"
    case .doubleTap: return "Double Tap"
    }
  }
}

/// An event emitted by the engine.
public struct HotKeyEvent: Sendable {
  public let gesture: HotKeyGesture
  public let timestamp: TimeInterval
  public let source: String

  public init(gesture: HotKeyGesture, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime, source: String = "") {
    self.gesture = gesture
    self.timestamp = timestamp
    self.source = source
  }
}

/// Opaque token returned from gesture registration; used to unregister.
public struct HotKeyListenerToken: Hashable, Sendable {
  let id: UUID
  let gesture: HotKeyGesture
}

/// Timing configuration for gesture detection.
public struct HotKeyConfiguration: Sendable {
  public var holdThreshold: TimeInterval
  public var doubleTapWindow: TimeInterval

  public init(holdThreshold: TimeInterval = 0.35, doubleTapWindow: TimeInterval = 0.4) {
    self.holdThreshold = holdThreshold
    self.doubleTapWindow = doubleTapWindow
  }
}

#endif
