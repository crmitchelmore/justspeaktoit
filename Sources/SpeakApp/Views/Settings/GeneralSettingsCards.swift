import AppKit
import SpeakCore
import SwiftUI

/// The microphone a new recording session prefers, beside the macOS default.
struct MicrophoneSettingsCard: View {
  @EnvironmentObject private var audioDevices: AudioInputDeviceManager

  var body: some View {
    SettingsCard(title: "Microphone", systemImage: "mic.circle", tint: Color.brandAccentWarm) {
      VStack(alignment: .leading, spacing: 12) {
        LongListPicker(
          title: "Preferred microphone",
          items: [LongListChoice(id: AudioInputDeviceManager.systemDefaultToken, title: "Use macOS default")]
            + audioDevices.devices.map { LongListChoice(id: $0.id, title: $0.displayName) },
          id: { $0.id }, selection: audioInputSelectionBinding, searchText: { [$0.title] },
          row: { item in
            Text(item.title)
          })
        .settingsMenuPicker()
        .speakTooltip("Choose a microphone for new recording sessions, or follow the macOS default.")
        .accessibilityLabel("Preferred microphone")

        if let details = audioDevices.currentSelectionDetails {
          Text(details)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 8) {
          Image(systemName: "waveform")
            .foregroundStyle(Color.brandAccentWarm)
          Text("macOS default now: \(audioDevices.systemDefaultDisplayName)")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button {
            audioDevices.refresh()
          } label: {
            Label("Refresh microphones", systemImage: "arrow.clockwise")
              .labelStyle(.titleAndIcon)
          }
          .buttonStyle(.bordered)
          .speakTooltip("Reload the list of connected microphones.")
        }
        Text(
          "Your preference applies when a new recording session starts. Speak temporarily switches "
            + "the macOS default to your chosen microphone, then restores it when the session ends. "
            + "If that microphone disconnects, the preference resets to Use macOS default."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .speakTooltip("Your preferred microphone and the current macOS default can differ between recording sessions.")
  }

  private var audioInputSelectionBinding: Binding<String> {
    Binding(
      get: {
        audioDevices.selectedDeviceUID ?? AudioInputDeviceManager.systemDefaultToken
      },
      set: { newValue in
        if newValue == AudioInputDeviceManager.systemDefaultToken {
          audioDevices.selectSystemDefault()
        } else {
          audioDevices.selectDevice(uid: newValue)
        }
      }
    )
  }
}

/// Start and stop sounds, with a preview player kept alive while it plays.
struct RecordingSoundsSettingsCard: View, AppSettingsBindingProviding {
  @EnvironmentObject var settings: AppSettings
  @State private var soundPreviewPlayer: RecordingSoundPlayer?

  var body: some View {
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
          .settingsMenuPicker()
        }

        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Volume")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Spacer()
            Text(Self.volumeLabel(for: settings.recordingSoundVolume))
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
            .accessibilityLabel("Volume")
            .accessibilityValue(Self.volumeLabel(for: settings.recordingSoundVolume))
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
  }

  static func volumeLabel(for volume: Float) -> String {
    let percent = Int(volume * 100)
    return "\(percent)%"
  }

  private func previewRecordingSound(_ sound: RecordingSoundPlayer.RecordingSound) {
    let player = RecordingSoundPlayer()
    player.profile = settings.recordingSoundProfile
    player.play(sound, volume: settings.recordingSoundVolume)
    soundPreviewPlayer = player
  }
}

/// The local automation socket behind the `speak` CLI and the MCP server.
struct AutomationServerSettingsCard: View, AppSettingsBindingProviding {
  @EnvironmentObject private var environment: AppEnvironment
  @EnvironmentObject var settings: AppSettings

  var body: some View {
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

        if settings.enableAutomationServer {
          settingsToggle(
            "Allow automation to change settings",
            isOn: settingsBinding(\AppSettings.allowAutomationConfigurationChanges),
            tint: Color.brandLagoon
          )
          .accessibilityIdentifier("automationAllowConfigurationChangesToggle")
          .settingsSearchAnchor(title: "Allow automation to change settings")
          .speakTooltip(
            "Lets \"speak config set\" and the MCP set_configuration tool change settings. "
              + "Reading settings and dry runs work without it."
          )
        }
      }
    }
    .speakTooltip("Control Speak from scripts, the terminal, or an AI agent over a local socket.")
  }
}

/// The recordings folder, and a way to clear it.
struct HousekeepingSettingsCard: View {
  @EnvironmentObject private var environment: AppEnvironment
  @EnvironmentObject private var settings: AppSettings
  @State private var isDeletingRecordings = false

  var body: some View {
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
  }
}
