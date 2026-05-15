#if os(macOS)
import AppKit
import SwiftUI

/// A SwiftUI view that lets users record a custom hotkey or select the Fn key.
///
/// Shows the current binding, enters "recording" mode on click to capture
/// a key combination, and includes a toggle for the Fn key option.
public struct HotKeyRecorder: View {
  @Binding var hotKey: HotKey
  @State private var isRecording = false
  @State private var pendingModifiers: HotKey.ModifierSet = []
  @State private var eventMonitor: Any?

  private let label: String

  public init(_ label: String = "Hotkey", hotKey: Binding<HotKey>) {
    self.label = label
    self._hotKey = hotKey
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(label)
          .font(.headline)
        Spacer()
        hotKeyDisplay
      }

      HStack(spacing: 12) {
        fnToggle
        Spacer()
        if !hotKey.isFnKey {
          clearButton
        }
      }
    }
    .onDisappear {
      stopRecording()
    }
    .onChange(of: hotKey) { _, newValue in
      if newValue.isFnKey {
        stopRecording()
      }
    }
  }

  // MARK: - Display

  private var hotKeyDisplay: some View {
    Button {
      if hotKey.isFnKey { return }
      if isRecording {
        stopRecording()
      } else {
        startRecording()
      }
    } label: {
      HStack(spacing: 4) {
        if isRecording {
          recordingView
        } else {
          Text(hotKey.displayString)
            .font(.system(.body, design: .rounded))
            .fontWeight(.medium)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isRecording ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(isRecording ? Color.accentColor : Color.clear, lineWidth: 1.5)
      )
    }
    .buttonStyle(.plain)
    .disabled(hotKey.isFnKey)
  }

  private var recordingView: some View {
    HStack(spacing: 4) {
      if !pendingModifiers.isEmpty {
        Text(pendingModifiers.displayString)
          .font(.system(.body, design: .rounded))
      }
      Text("Press a key…")
        .foregroundStyle(.secondary)
        .font(.caption)
    }
  }

  // MARK: - Fn Toggle

  private var fnToggle: some View {
    Toggle(isOn: Binding(
      get: { hotKey.isFnKey },
      set: { useFn in
        if useFn {
          stopRecording()
          hotKey = .fnKey
        } else {
          hotKey = .custom(keyCode: 49, modifiers: .option)  // Default: ⌥Space
        }
      }
    )) {
      HStack(spacing: 4) {
        Text("🌐")
        Text("Use Fn key")
          .font(.subheadline)
      }
    }
    .toggleStyle(.checkbox)
  }

  private var clearButton: some View {
    Button {
      stopRecording()
      hotKey = .custom(keyCode: 49, modifiers: .option)
    } label: {
      Text("Reset")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
  }

  // MARK: - Key Recording

  private func startRecording() {
    stopRecording()
    isRecording = true
    pendingModifiers = []
    NotificationCenter.default.post(name: .speakHotKeyShouldPause, object: nil)

    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
      handleKeyEvent(event) ? nil : event
    }
  }

  private func stopRecording() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
    if isRecording {
      isRecording = false
      pendingModifiers = []
      NotificationCenter.default.post(name: .speakHotKeyDidChange, object: nil)
    }
  }

  private func handleKeyEvent(_ event: NSEvent) -> Bool {
    // Track modifier-only presses
    if KeyCodeMapping.modifierKeyCodes.contains(event.keyCode) {
      pendingModifiers = HotKey.ModifierSet(from: event.modifierFlags)
      return true
    }

    // Escape cancels recording
    if event.keyCode == 53 && pendingModifiers.isEmpty {
      stopRecording()
      return true
    }

    // Record the shortcut
    let modifiers = HotKey.ModifierSet(
      from: event.modifierFlags.intersection([.command, .shift, .option, .control])
    )

    // Allow dedicated extended keys as single-key hotkeys, but keep ordinary typing keys modifier-gated.
    guard !modifiers.isEmpty || KeyCodeMapping.singleKeyHotKeyCodes.contains(event.keyCode) else { return true }

    hotKey = .custom(keyCode: event.keyCode, modifiers: modifiers)
    stopRecording()
    return true
  }
}

// MARK: - Modifier Display

extension HotKey.ModifierSet {
  var displayString: String {
    var parts: [String] = []
    if contains(.control) { parts.append("⌃") }
    if contains(.option) { parts.append("⌥") }
    if contains(.shift) { parts.append("⇧") }
    if contains(.command) { parts.append("⌘") }
    return parts.joined()
  }
}

// MARK: - Hotkey Lifecycle Notifications

public extension Notification.Name {
  /// Posted while recording a replacement hotkey so the active binding does not steal key events.
  static let speakHotKeyShouldPause = Notification.Name("speak.hotKeyShouldPause")

  /// Posted after recording finishes so the active hotkey can be re-registered.
  static let speakHotKeyDidChange = Notification.Name("speak.hotKeyDidChange")
}

#endif
