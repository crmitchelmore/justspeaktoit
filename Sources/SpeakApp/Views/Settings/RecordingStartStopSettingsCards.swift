import SpeakCore
import SwiftUI

/// How a recording starts and stops, and the delay that applies to the
/// selected transcription mode.
struct RecordingStartStopSettingsCards: View, AppSettingsBindingProviding {
  @EnvironmentObject var settings: AppSettings

  @ViewBuilder
  var body: some View {
    // 4. How a recording starts and stops.
    handsFreeDictationCard
    if !settings.isStreamingTranscriptionSelected {
      silenceDetectionCard
    }

    // 5. Fine-tuning delays. Only one applies to the selected mode.
    if settings.isStreamingTranscriptionSelected {
      streamingStopGraceCard
    } else {
      recordingBufferCard
    }
  }

  /// Arm-on-hotkey voice activation (Apple on-device streaming only).
  private var handsFreeDictationCard: some View {
    SettingsCard(
      title: "Hands-free dictation",
      systemImage: "waveform.badge.mic",
      tint: Color.brandLagoon
    ) {
      let captureConfigurationSupported = HandsFreeDictationPolicy.supportsCapture(
        modelID: settings.liveTranscriptionModel,
        isStreaming: settings.transcriptionMode == .liveNative
      )
      VStack(alignment: .leading, spacing: 12) {
        Toggle(
          "Arm on hotkey instead of recording",
          isOn: settingsBinding(\AppSettings.handsFreeDictationEnabled)
        )
        .disabled(!settings.handsFreeDictationSupported || !captureConfigurationSupported)
        .accessibilityIdentifier("handsFreeDictationToggle")
        .speakTooltip("Your hotkey starts listening; speaking starts recording and silence stops it.")

        if settings.handsFreeDictationSupported {
          Text(
            "The hotkey arms a listening session instead of recording straight away. "
              + "Recording starts when you speak and stops after the silence duration below. "
              + "Silent audio stays in memory only and is discarded immediately. "
              + "Press the hotkey again to disarm."
          )
          .font(.caption)
          .foregroundStyle(.secondary)

          if !captureConfigurationSupported {
            Text("Select an Apple on-device streaming model to use hands-free dictation.")
              .font(.caption)
              .foregroundStyle(.orange)
          }

          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Silence duration")
                .font(.caption)
              Spacer()
              Text(settings.silenceDuration, format: .number.precision(.fractionLength(1)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
              Text("sec")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Slider(
              value: settingsBinding(\AppSettings.silenceDuration),
              in: 0.5...5.0,
              step: 0.5
            )
            .accessibilityLabel("Silence duration")
            .accessibilityValue(String(format: "%.1f seconds", settings.silenceDuration))
            .speakTooltip("How long to wait in silence before stopping hands-free recording.")
          }
        } else {
          Text("Requires macOS 26 or later — Apple's on-device speech detector isn't available here.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .speakTooltip("Voice-activated dictation using Apple's on-device speech detector.")
  }

  /// Auto-stop after silence for batch modes.
  private var silenceDetectionCard: some View {
    SettingsCard(title: "Silence detection", systemImage: "waveform.slash", tint: Color.brandAccentWarm) {
      VStack(alignment: .leading, spacing: 12) {
        Toggle(
          "Auto-stop on silence",
          isOn: settingsBinding(\AppSettings.silenceDetectionEnabled)
        )
        .speakTooltip("Automatically stop recording when you stop speaking.")

        if settings.silenceDetectionEnabled {
          Text("Stops recording after a period of silence, useful for hands-free operation.")
            .font(.caption)
            .foregroundStyle(.secondary)

          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Silence threshold")
                .font(.caption)
              Spacer()
              Text("\(Int(settings.silenceThreshold * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Slider(
              value: settingsBinding(\AppSettings.silenceThreshold),
              in: 0.01...0.2,
              step: 0.01
            )
            .accessibilityLabel("Silence threshold")
            .accessibilityValue("\(Int(settings.silenceThreshold * 100))%")
            .speakTooltip("Audio levels below this are considered silence. Lower = more sensitive.")
          }

          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Silence duration")
                .font(.caption)
              Spacer()
              Text(settings.silenceDuration, format: .number.precision(.fractionLength(1)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
              Text("sec")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Slider(
              value: settingsBinding(\AppSettings.silenceDuration),
              in: 0.5...5.0,
              step: 0.5
            )
            .accessibilityLabel("Silence duration")
            .accessibilityValue(String(format: "%.1f seconds", settings.silenceDuration))
            .speakTooltip("How long to wait in silence before auto-stopping.")
          }
        }
      }
    }
    .speakTooltip("Configure automatic recording stop based on silence detection.")
  }

  /// Extra time to flush final words from a streaming session.
  private var streamingStopGraceCard: some View {
    SettingsCard(
      title: "Streaming stop grace",
      systemImage: "waveform.and.mic",
      tint: Color.brandAccentDeep
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Text(
          """
          After stopping, keep the streaming transcription connection open briefly so providers \
          or local streaming runtimes can flush their final words. Applied to Remote \
          Streaming providers and Local Streaming.
          """
        )
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack {
          Slider(
            value: settingsBinding(\AppSettings.liveStopGracePeriod),
            in: 0...2,
            step: 0.1
          )
          .accessibilityLabel("Streaming stop grace")
          .accessibilityValue(String(format: "%.1f seconds", settings.liveStopGracePeriod))
          .speakTooltip("Extra delay before closing the streaming transcription connection after you stop recording.")
          Text(
            settings.liveStopGracePeriod,
            format: .number.precision(.fractionLength(1))
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          Text("sec")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .speakTooltip("Helps reduce last-word cutoffs across Remote Streaming providers and Local Streaming.")
  }

  /// Trailing capture after the hotkey is released in batch modes.
  private var recordingBufferCard: some View {
    SettingsCard(title: "Recording buffer", systemImage: "waveform.path.ecg", tint: Color.brandLagoon) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Keep recording for a moment after you let go to capture trailing words.")
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack {
          Slider(
            value: settingsBinding(\AppSettings.postRecordingTailDuration),
            in: 0...2,
            step: 0.1
          )
          .accessibilityLabel("Recording buffer")
          .accessibilityValue(String(format: "%.1f seconds", settings.postRecordingTailDuration))
          .speakTooltip("Control how long Speak keeps capturing after you finish talking.")
          Text(
            settings.postRecordingTailDuration,
            format: .number.precision(.fractionLength(1))
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          Text("sec")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .speakTooltip("Decide how much breathing room Speak gives you after releasing your shortcut.")
  }
}
