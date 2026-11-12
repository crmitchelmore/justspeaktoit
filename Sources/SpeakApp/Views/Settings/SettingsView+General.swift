import SpeakCore
import SpeakHotKeys
import SpeakSync
import AppKit
import SwiftUI

extension SettingsView {
  var generalSettings: some View {
    SpeakDensitySettingsSection(density: settings.visualDensity) {
      MicrophoneSettingsCard()

      SettingsCard(title: "Language", systemImage: "character.bubble", tint: Color.brandAccentWarm) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Choose the spoken language sent to transcription models across every recording surface.")
            .font(.callout)
            .foregroundStyle(.secondary)

          LongListPicker(
            title: "Spoken Language", items: TranscriptionLanguageCatalog.options,
            id: { $0.id }, selection: settingsBinding(\AppSettings.preferredLocaleIdentifier),
            searchText: { [$0.displayName, $0.id] },
            row: { option in
            Text(option.displayName)
          })
          .settingsMenuPicker()
          .speakTooltip(
            "Automatic lets remote providers detect the language. Apple speech uses your current system locale."
          )
          .accessibilityLabel("Spoken language picker")
        }
      }
      .speakTooltip("Set the language preference used by local and remote transcription models.")

      SettingsCard(title: "Output", systemImage: "textformat.alt", tint: Color.brandLagoon) {
        VStack(alignment: .leading, spacing: 12) {
          if DistributionChannel.current.supportsAccessibilityTextInsertion {
            Picker("Text Output", selection: settingsBinding(\AppSettings.textOutputMethod)) {
              ForEach(AppSettings.availableTextOutputMethods(for: DistributionChannel.current)) { method in
                Text(method.displayName).tag(method)
              }
            }
            .settingsMenuPicker()
            .speakTooltip("Decide how Speak returns transcripts—typed for you or placed on the clipboard.")
            .accessibilityLabel("Text output method picker")
          } else {
            Label("Clipboard delivery", systemImage: "doc.on.clipboard")
              .font(.subheadline.weight(.medium))
            Text(
              "The App Store sandbox blocks changing text in other apps. "
                + "Transcripts stay on the clipboard, ready to paste."
            )
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          if DistributionChannel.current.supportsAccessibilityTextInsertion,
             settings.textOutputMethod != .clipboardOnly {
            Picker("Accessibility Insertion", selection: settingsBinding(\AppSettings.accessibilityInsertionMode)) {
              ForEach(AppSettings.AccessibilityInsertionMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
              }
            }
            .settingsMenuPicker()
            .speakTooltip(
              "Insert at Cursor adds text where your cursor is. Replace Field overwrites the entire text field."
            )

            Text(settings.accessibilityInsertionMode == .insertAtCursor
              ? "Text will be inserted at your cursor position, preserving existing content."
              : "Text will replace the entire contents of the focused text field.")
              .font(.caption)
              .foregroundStyle(.secondary)

            settingsToggle(
              "Stream text while dictating (experimental)",
              isOn: settingsBinding(\AppSettings.streamingInsertionEnabled),
              tint: .brandLagoon
            )
            .speakTooltip(
              "Type words into supported apps (TextEdit, Notes) as you speak, correcting them live. "
                + "Other apps keep the normal paste-at-end behaviour."
            )
          }
          VStack(alignment: .leading, spacing: 8) {
            if DistributionChannel.current.supportsAccessibilityTextInsertion {
              Picker(
                AppSettings.AppSwitchDelivery.settingName,
                selection: settingsBinding(\AppSettings.appSwitchDelivery)
              ) {
                ForEach(AppSettings.AppSwitchDelivery.allCases) { option in
                  Text(option.displayName).tag(option)
                }
              }
              .settingsMenuPicker()
              .speakTooltip(
                "Choose where your transcript goes if you switch apps while recording or transcribing."
              )
              .accessibilityLabel("App switch delivery picker")
              Text(settings.appSwitchDelivery.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              settingsToggle(
                "Restore clipboard after paste",
                isOn: settingsBinding(\AppSettings.restoreClipboardAfterPaste),
                tint: .brandLagoon
              )
              .speakTooltip(
                "After Speak pastes your transcript, we put your original clipboard content back automatically."
              )
              settingsToggle(
                "Paste iPhone and Watch transcripts at the cursor",
                isOn: settingsBinding(\AppSettings.pasteRemoteTranscriptsAtCursor),
                tint: .brandLagoon
              )
              .speakTooltip(
                "Off by default. When off, a capture from your iPhone or Apple Watch arrives as a "
                  + "notification with Paste and Copy. When on, a capture made in the last minute is "
                  + "pasted wherever your cursor is, which can overwrite a selection."
              )
            }
          }
        }
      }
      .speakTooltip("Control how Speak delivers transcripts and how gently we touch your clipboard and interface.")

      SettingsCard(title: "App Behaviour", systemImage: "gearshape.2", tint: Color.brandAccentWarm) {
        VStack(alignment: .leading, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Show App In")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Picker("Show App In", selection: settingsBinding(\AppSettings.appVisibility)) {
              ForEach(AppSettings.AppVisibility.allCases) { visibility in
                Text(visibility.displayName).tag(visibility)
              }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
          }
          .settingsControlChrome()
          .speakTooltip(
            "Choose where Speak appears - in the Dock, menu bar, or both. Menu bar only keeps it out of the way."
          )

          if settings.appVisibility == .dockOnly {
            settingsToggle(
              "Show status bar icon",
              isOn: settingsBinding(\AppSettings.showStatusBarIconInDockOnly),
              tint: .brandAccentWarm
            )
            .speakTooltip(
              "Keep the Speak icon in the menu bar for quick access while the app lives in the Dock. "
                + "Turn off for a Dock-only experience."
            )
          }

          settingsToggle(
            "Compact status bar icon",
            isOn: settingsBinding(\AppSettings.compactStatusBarIcon),
            tint: .brandAccentWarm
          )
          .speakTooltip(
            "Compact hides the “Speak” label and colour-codes the icon by state, "
              + "keeping the menu bar tidy. Turn off for the Labelled style with status text."
          )

          VStack(alignment: .leading, spacing: 8) {
            settingsToggle(
              "Launch at login",
              isOn: settingsBinding(\AppSettings.runAtLogin),
              tint: .brandAccentWarm
            )
            .speakTooltip("Have Speak start alongside macOS so recording is always one shortcut away.")
            if updaterManager.supportsSelfUpdate {
              Toggle("Automatically check for updates", isOn: $updaterManager.automaticallyChecksForUpdates)
                .toggleStyle(.switch)
                .tint(.brandAccentWarm)
                .speakTooltip("Periodically check for new versions and notify you when updates are available.")
            } else {
              Label(updaterManager.updateStatusMessage, systemImage: "app.badge")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            settingsToggle(
              "Show sidebar shortcut hints",
              isOn: settingsBinding(\AppSettings.showSidebarShortcutHints),
              tint: .brandAccentWarm
            )
            .speakTooltip("Show discreet keyboard shortcut hints beside the left menu items.")
          }
        }
      }
      .speakTooltip("Configure how Speak integrates with your Mac—where it appears and when it starts.")

      SettingsCard(title: "Appearance", systemImage: "paintpalette", tint: Color.brandAccent) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Choose how Speak looks across light, dark, or system themes.")
            .font(.callout)
            .foregroundStyle(.secondary)
          Picker("Theme", selection: settingsBinding(\AppSettings.appearance)) {
            ForEach(AppSettings.Appearance.allCases) { appearance in
              Text(appearance.rawValue.capitalized).tag(appearance)
            }
          }
          .settingsSegmentedPicker()
          .speakTooltip("Choose whether Speak follows macOS appearance or stays in light or dark mode all the time.")
          .accessibilityLabel("Appearance theme picker")

          Picker("Layout Density", selection: settingsBinding(\AppSettings.visualDensity)) {
            ForEach(AppVisualDensity.allCases) { density in
              Text(density.displayName).tag(density)
            }
          }
          .settingsSegmentedPicker()
          .speakTooltip("Choose normal spacing or a higher-density layout across Speak.")
          .accessibilityLabel("Application layout density picker")
        }
      }
      .speakTooltip("Set Speak's look to match your workspace with light, dark, or system themes.")

      SettingsCard(title: "Heads-Up Display", systemImage: "rectangle.on.rectangle", tint: Color.brandLagoon) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Choose what Speak shows while a recording or transcription session is active.")
            .font(.callout)
            .foregroundStyle(.secondary)

          VStack(alignment: .leading, spacing: 8) {
            settingsToggle(
              "Show HUD during sessions",
              isOn: settingsBinding(\AppSettings.showHUDDuringSessions),
              tint: .brandLagoon
            )
            .speakTooltip("Display a small heads-up display so you always know when Speak is listening.")
            settingsToggle(
              "Show live transcript in HUD",
              isOn: settingsBinding(\AppSettings.showLiveTranscriptInHUD),
              tint: .brandLagoon
            )
            .speakTooltip("Show real-time transcription text in the HUD while recording, full or compact.")
            settingsToggle(
              "Show compact HUD",
              isOn: settingsBinding(\AppSettings.showCompactHUD),
              tint: .brandLagoon
            )
            .speakTooltip(
              "Shrink the HUD to a pulsing dot, a live level meter and the timer. The scrolling "
                + "transcript line still follows the \"Show live transcript in HUD\" setting above."
            )
            settingsToggle(
              "Shorten error display",
              isOn: settingsBinding(\AppSettings.shortenErrorDisplay),
              tint: .brandLagoon
            )
            .speakTooltip(
              "Auto-dismiss failure and cancellation messages after 3.6 seconds instead of 6, "
                + "so they don't linger far longer than a success confirmation."
            )
          }
        }
      }
      .speakTooltip("Configure the HUD shown while Speak is listening and transcribing.")

      RecordingSoundsSettingsCard()

      SettingsCard(title: "Fast Start", systemImage: "bolt.circle", tint: Color.brandAccentWarm) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Prepare recording ahead of time so dictation begins the moment you press your shortcut.")
            .font(.callout)
            .foregroundStyle(.secondary)

          settingsToggle(
            "Prepare recording while idle",
            isOn: settingsBinding(\AppSettings.audioPreWarmingEnabled),
            tint: .brandAccentWarm
          )
          .speakTooltip(
            "Sets up the recorder in advance so your shortcut starts capture immediately. "
              + "The microphone is never opened until you actually start dictating."
          )

          settingsToggle(
            "Warm supported connections",
            isOn: settingsBinding(\AppSettings.connectionPreWarmingEnabled),
            tint: .brandAccentWarm
          )
          .speakTooltip(
            "Probes supported provider endpoints ahead of time without opening a live session. "
              + "No audio, API key, or transcription request is sent while idle."
          )
        }
      }
      .speakTooltip("Trade a little idle work for a faster start when you press your dictation shortcut.")

      SendToMacSettingsCard()

      ICloudSyncSettingsCard()

      AutomationServerSettingsCard()

      automationCLICard

      HousekeepingSettingsCard()

      SettingsCard(title: "Advanced", systemImage: "gearshape.2", tint: Color.gray) {
        VStack(alignment: .leading, spacing: 12) {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text("History Flush Interval")
              Spacer()
              Text(
                settings.historyFlushInterval, format: .number.precision(.fractionLength(1))
              )
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              Text("sec")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Slider(
              value: settingsBinding(\AppSettings.historyFlushInterval),
              in: 1...30,
              step: 1
            )
            .speakTooltip(
              "Control how often Speak writes history to disk. "
                + "Lower values save more frequently but may impact performance."
            )
            Text(
              "How often pending history writes are flushed to disk. "
                + "Lower values reduce potential data loss but increase I/O."
            )
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .speakTooltip("Fine-tune advanced performance settings for power users.")
    }
  }
}
