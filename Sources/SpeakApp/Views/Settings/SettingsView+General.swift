// swiftlint:disable file_length
import SpeakCore
import SpeakHotKeys
import SpeakSync
import AppKit
import SwiftUI

extension SettingsView {
  var generalSettings: some View {
    SpeakDensitySettingsSection(density: settings.visualDensity) {
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
          .pickerStyle(.segmented)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
          )
          .speakTooltip("Choose whether Speak follows macOS appearance or stays in light or dark mode all the time.")
          .accessibilityLabel("Appearance theme picker")

          Picker("Layout Density", selection: settingsBinding(\AppSettings.visualDensity)) {
            ForEach(AppVisualDensity.allCases) { density in
              Text(density.displayName).tag(density)
            }
          }
          .pickerStyle(.segmented)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
          )
          .speakTooltip("Choose normal spacing or a higher-density layout across Speak.")
          .accessibilityLabel("Application layout density picker")
        }
      }
      .speakTooltip("Set Speak's look to match your workspace with light, dark, or system themes.")

      SettingsCard(title: "Language", systemImage: "character.bubble", tint: Color.brandAccentWarm) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Choose the spoken language sent to transcription models across every recording surface.")
            .font(.callout)
            .foregroundStyle(.secondary)

          Picker("Spoken Language", selection: settingsBinding(\AppSettings.preferredLocaleIdentifier)) {
            ForEach(TranscriptionLanguageCatalog.options) { option in
              Text(option.displayName).tag(option.id)
            }
          }
          .pickerStyle(.menu)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
          )
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
            .pickerStyle(.menu)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            )
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
            .pickerStyle(.menu)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            )
            .speakTooltip("Insert at Cursor adds text where your cursor is. Replace Field overwrites the entire text field.")

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
              settingsToggle(
                "Restore clipboard after paste",
                isOn: settingsBinding(\AppSettings.restoreClipboardAfterPaste),
                tint: .brandLagoon
              )
              .speakTooltip(
                "After Speak pastes your transcript, we put your original clipboard content back automatically."
              )
            }
          }
        }
      }
      .speakTooltip("Control how Speak delivers transcripts and how gently we touch your clipboard and interface.")

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
          }
        }
      }
      .speakTooltip("Configure the HUD shown while Speak is listening and transcribing.")

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
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
          )
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

      SettingsCard(title: "Microphone", systemImage: "mic.circle", tint: Color.brandAccentWarm) {
        VStack(alignment: .leading, spacing: 12) {
          Picker("Input Device", selection: audioInputSelectionBinding) {
            Text("System Default (\(audioDevices.systemDefaultDisplayName))")
              .tag(AudioInputDeviceManager.systemDefaultToken)
            ForEach(audioDevices.devices) { device in
              Text(device.displayName).tag(device.id)
            }
          }
          .pickerStyle(.menu)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
          )
          .speakTooltip("Choose which microphone Speak listens to when recording or transcribing.")
          .accessibilityLabel("Audio input device picker")

          if let details = audioDevices.currentSelectionDetails {
            Text(details)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

            HStack(spacing: 8) {
              Image(systemName: "waveform")
                .foregroundStyle(Color.brandAccentWarm)
              Text("Currently active: \(audioDevices.systemDefaultDisplayName)")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button {
              audioDevices.refresh()
            } label: {
              Label("Refresh", systemImage: "arrow.clockwise")
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .speakTooltip("Reload the list of connected microphones.")
          }
        }
      }
      .speakTooltip("Pick the microphone Speak should use. We fall back to the system default if a device disconnects.")

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

      SettingsCard(title: "Recording Sounds", systemImage: "speaker.wave.2", tint: Color.brandLagoon) {
        VStack(alignment: .leading, spacing: 12) {
          settingsToggle(
            "Play start/stop sounds",
            isOn: settingsBinding(\AppSettings.recordingSoundsEnabled),
            tint: .brandLagoon
          )
          .speakTooltip("Play a short sound when recording starts or ends.")

          VStack(alignment: .leading, spacing: 6) {
            Text("Sound profile")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Picker("Sound profile", selection: settingsBinding(\AppSettings.recordingSoundProfile)) {
              ForEach(RecordingSoundPlayer.SoundProfile.allCases) { profile in
                Text(profile.displayName).tag(profile)
              }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            )
          }

          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text("Volume")
                .font(.subheadline)
                .foregroundStyle(.secondary)
              Spacer()
              Text(volumeLabel(for: settings.recordingSoundVolume))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }
            HStack(spacing: 8) {
              Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
              Slider(
                value: settingsBinding(\AppSettings.recordingSoundVolume),
                in: 0.02...1.0,
                step: 0.02
              )
              Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
            }
          }

          HStack(spacing: 12) {
            Button("Preview Start") {
              previewRecordingSound(.start)
            }
            .buttonStyle(.bordered)

            Button("Preview Stop") {
              previewRecordingSound(.stop)
            }
            .buttonStyle(.bordered)
          }
        }
      }
      .speakTooltip("Choose the sound that plays when Speak starts or stops recording.")

      SettingsCard(title: "Send to Mac", systemImage: "iphone.and.arrow.forward", tint: Color.green) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Allow iOS devices to send transcripts to this Mac over your local network.")
            .font(.callout)
            .foregroundStyle(.secondary)

          settingsToggle(
            "Enable Send to Mac",
            isOn: Binding(
              get: { settings.enableSendToMac },
              set: { newValue in
                settings.enableSendToMac = newValue
                if newValue {
                  do {
                    try environment.transportServer.start()
                  } catch {
                    // Reflect reality: the listener did not start, so flip the
                    // toggle back off and let the error label explain why.
                    settings.enableSendToMac = false
                  }
                } else {
                  environment.transportServer.stop()
                }
              }
            ),
            tint: .green
          )
          .speakTooltip(
            "When enabled, your Mac will advertise itself on the local network and accept connections from Speak iOS."
          )

          if let transportError = environment.transportServer.error,
             !environment.transportServer.isRunning {
            Label(
              "Send to Mac could not start: \(transportError.localizedDescription)",
              systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
          }

          if settings.enableSendToMac {
            Divider()

            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text("Pairing Code:")
                  .font(.headline)
                Spacer()
                Text(PairingManager.shared.pairingCode)
                  .font(.system(.title2, design: .monospaced))
                  .fontWeight(.bold)
                  .foregroundStyle(.green)
                Button {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(PairingManager.shared.pairingCode, forType: .string)
                } label: {
                  Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .speakTooltip("Copy pairing code to clipboard")
              }

              Text("Enter this code on your iPhone when pairing.")
                .font(.caption)
                .foregroundStyle(.secondary)

              Button("Regenerate Code") {
                _ = PairingManager.shared.regeneratePairingCode()
              }
              .buttonStyle(.bordered)
              .speakTooltip("Generate a new pairing code. This will disconnect all paired devices.")
            }
            .padding()
            .background(
              RoundedRectangle(cornerRadius: 8)
                .fill(Color.green.opacity(0.1))
            )

            if environment.transportServer.isRunning {
              HStack(spacing: 6) {
                Circle()
                  .fill(.green)
                  .frame(width: 8, height: 8)
                Text("Server running, ready for connections")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }

            if !environment.transportServer.connectedDevices.isEmpty {
              Divider()

              VStack(alignment: .leading, spacing: 8) {
                Text("Connected Devices:")
                  .font(.headline)

                ForEach(environment.transportServer.connectedDevices) { device in
                  HStack {
                    Image(systemName: "iphone")
                      .foregroundStyle(Color.brandLagoon)
                    VStack(alignment: .leading, spacing: 2) {
                      Text(device.name)
                        .font(.subheadline)
                      Text("Connected \(device.connectedAt, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                      environment.transportServer.disconnectDevice(id: device.id)
                    } label: {
                      Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .speakTooltip("Disconnect this device")
                  }
                  .padding(8)
                  .background(
                    RoundedRectangle(cornerRadius: 6)
                      .fill(Color(nsColor: .controlBackgroundColor))
                  )
                }
              }
            }
          }
        }
      }
      .speakTooltip("Use your iPhone as a wireless microphone. Transcribe on iPhone, text appears on Mac.")

      SettingsCard(title: "Automation", systemImage: "terminal", tint: Color.brandLagoon) {
        VStack(alignment: .leading, spacing: 12) {
          Text(
            "Let the \"speak\" command-line tool and the bundled MCP server drive dictation on this Mac. "
              + "While this is on, any app or script running under your macOS account can start the "
              + "microphone and read your transcription history."
          )
          .font(.callout)
          .foregroundStyle(.secondary)

          settingsToggle(
            "Enable automation (speak CLI and MCP)",
            isOn: Binding(
              get: { settings.enableAutomationServer },
              set: { newValue in
                settings.enableAutomationServer = newValue
                if newValue {
                  do {
                    try environment.startAutomationServer()
                  } catch {
                    // Reflect reality: the socket did not open, so the toggle
                    // must not claim automation is available.
                    settings.enableAutomationServer = false
                  }
                } else {
                  environment.stopAutomationServer()
                }
              }
            ),
            tint: Color.brandLagoon
          )
          .speakTooltip(
            "When enabled, Speak listens on a private socket in your home folder for automation commands."
          )
        }
      }
      .speakTooltip("Control Speak from scripts, the terminal, or an AI agent over a local socket.")

      automationCLICard

      SettingsCard(title: "Housekeeping", systemImage: "tray.full", tint: Color.brandAccentWarm) {
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder")
              .foregroundStyle(Color.brandAccentWarm)
            VStack(alignment: .leading, spacing: 6) {
              Text("Recordings directory")
                .font(.headline)
              Text(settings.recordingsDirectory.path)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reveal") {
              NSWorkspace.shared.activateFileViewerSelecting([
                settings.recordingsDirectory
              ])
            }
            .buttonStyle(.bordered)
            .speakTooltip("Open the folder where Speak saves raw audio so you can manage it yourself.")
          }

          Button {
            isDeletingRecordings = true
            Task {
              let recordings = await environment.audio.listRecordings()
              for recording in recordings {
                await environment.audio.removeRecording(at: recording.url)
              }
              await MainActor.run { isDeletingRecordings = false }
            }
          } label: {
            Label("Delete all recordings", systemImage: "trash")
          }
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .disabled(isDeletingRecordings)
          .speakTooltip("Permanently delete every saved audio file from your recordings folder.")
        }
      }
      .speakTooltip("Manage where your audio lives and tidy up archives when you're ready.")

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
            .speakTooltip("Control how often Speak writes history to disk. Lower values save more frequently but may impact performance.")
            Text("How often pending history writes are flushed to disk. Lower values reduce potential data loss but increase I/O.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .speakTooltip("Fine-tune advanced performance settings for power users.")
    }
  }
}
