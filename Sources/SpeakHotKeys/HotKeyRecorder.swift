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
  }

  // MARK: - Display

  private var hotKeyDisplay: some View {
    Button {
      if hotKey.isFnKey { return }
      isRecording.toggle()
      if isRecording {
        pendingModifiers = []
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
    .onKeyDown { event in
      guard isRecording else { return false }
      return handleKeyEvent(event)
    }
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
          isRecording = false
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
      isRecording = false
      hotKey = .custom(keyCode: 49, modifiers: .option)
    } label: {
      Text("Reset")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
  }

  // MARK: - Key Recording

  private func handleKeyEvent(_ event: NSEvent) -> Bool {
    // Track modifier-only presses
    if KeyCodeMapping.modifierKeyCodes.contains(event.keyCode) {
      pendingModifiers = HotKey.ModifierSet(from: event.modifierFlags)
      return true
    }

    // Escape cancels recording
    if event.keyCode == 53 && pendingModifiers.isEmpty {
      isRecording = false
      return true
    }

    // Record the shortcut
    let modifiers = HotKey.ModifierSet(
      from: event.modifierFlags.intersection([.command, .shift, .option, .control])
    )

    // Require at least one modifier for non-function keys
    guard !modifiers.isEmpty else { return true }

    hotKey = .custom(keyCode: event.keyCode, modifiers: modifiers)
    isRecording = false
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

// MARK: - Key Event Interception

/// View modifier that intercepts keyDown events via a local event monitor.
private struct KeyDownMonitor: ViewModifier {
    let handler: (NSEvent) -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    handler(event) ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

extension View {
    func onKeyDown(handler: @escaping (NSEvent) -> Bool) -> some View {
        modifier(KeyDownMonitor(handler: handler))
    }
}

#endif
