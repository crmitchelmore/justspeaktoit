import SpeakCore
import SpeakHotKeys
import SpeakSync
import AppKit
import SwiftUI

extension SettingsView {
  var keyboardSettings: some View {
    VStack(spacing: settings.visualDensity.sectionSpacing) {
      hotKeySettings
      ShortcutsSettingsView(shortcutManager: environment.shortcuts)
    }
  }

  private var hotKeySettings: some View {
    SpeakDensitySettingsSection(density: settings.visualDensity) {
      SettingsCard(title: "Trigger Key", systemImage: "keyboard", tint: Color.blue) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Choose which key triggers recording.")
            .font(.caption)
            .foregroundStyle(.secondary)

          VStack(alignment: .leading, spacing: 4) {
            Text("Custom Shortcut")
              .font(.caption)
              .foregroundStyle(.secondary)
            HotKeyRecorder(
              "Shortcut",
              hotKey: Binding(
                get: { self.settings.selectedHotKey },
                set: { newKey in
                  self.settings.selectedHotKey = newKey
                  self.environment.hotKeys.restartWithCurrentHotKey()
                }
              )
            )
            .frame(maxWidth: 200)
          }
        }
      }
      .speakTooltip("Pick the Fn key or record a custom keyboard shortcut for recording.")

      SettingsCard(title: "Activation", systemImage: "command.square", tint: Color.yellow) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Choose how the hotkey controls recording.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Picker("Activation", selection: settingsBinding(\AppSettings.hotKeyActivationStyle)) {
            ForEach(AppSettings.HotKeyActivationStyle.allCases) { style in
              Text(style.displayName).tag(style)
            }
          }
          .settingsSegmentedPicker()
          .speakTooltip("Decide whether you press, hold, or double-tap the hotkey to start a session.")
        }
      }
      .speakTooltip("Choose how the hotkey behaves when you start and stop recordings.")

      SettingsCard(title: "Timing", systemImage: "timer", tint: Color.orange) {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text("Hold Threshold")
              Spacer()
              Text(
                settings.holdThreshold, format: .number.precision(.fractionLength(2))
              )
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            }
            Slider(value: settingsBinding(\AppSettings.holdThreshold), in: 0.2...1.5, step: 0.05)
            .speakTooltip("Decide how long you must hold the shortcut before Speak starts recording.")
          }

          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text("Double Tap Window")
              Spacer()
              Text(
                settings.doubleTapWindow, format: .number.precision(.fractionLength(2))
              )
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            }
            Slider(value: settingsBinding(\AppSettings.doubleTapWindow), in: 0.2...1.0, step: 0.05)
            .speakTooltip("Set the gap allowed between taps when you double-press to trigger Speak.")
          }
        }
      }
      .speakTooltip("Fine-tune how long you hold or double-tap the shortcut before Speak responds.")
    }
  }
}
