import SpeakCore
import SwiftUI

/// Chooses where the draft text comes from.
struct VoiceOutputInputSourceCard: View {
  @ObservedObject var composer: VoiceOutputComposer

  var body: some View {
    SpeakDensityCard(title: "Input Source", systemImage: "arrow.down.doc", tint: .brandLagoon) {
      VStack(alignment: .leading, spacing: 12) {
        ViewThatFits(in: .horizontal) {
          self.sourcePicker
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

          self.sourcePicker
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: self.composer.inputSource) { _, newValue in
          self.composer.inputSourceChanged(to: newValue)
        }

        if self.composer.inputSource == .clipboard {
          Button("Load from Clipboard") {
            self.composer.loadFromClipboard()
          }
          .buttonStyle(.bordered)
        } else if self.composer.inputSource == .file {
          Button("Choose File…") {
            self.composer.isImportingFile = true
          }
          .buttonStyle(.bordered)
        }
      }
    }
  }

  private var sourcePicker: some View {
    Picker("Source", selection: self.$composer.inputSource) {
      ForEach(TTSInputSource.allCases) { source in
        Label(source.displayName, systemImage: source.icon).tag(source)
      }
    }
  }
}

/// Picks and previews the voice the draft is spoken in.
struct VoiceOutputVoiceCard: View {
  @ObservedObject var composer: VoiceOutputComposer
  @EnvironmentObject private var tts: TextToSpeechManager
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
    SpeakDensityCard(title: "Voice", systemImage: "person.wave.2", tint: .brandAccent) {
      VStack(alignment: .leading, spacing: 12) {
        self.voiceListingFailureNotice
        if self.composer.availableVoices.isEmpty {
          HStack {
            ProgressView()
              .scaleEffect(0.7)
            Text("Loading voices…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } else {
          VoicePicker(
            voices: VoiceCatalog.includingSelection(self.composer.selectedVoice, in: self.composer.availableVoices),
            storedAPIKeyIdentifiers: self.settings.trackedAPIKeyIdentifiers,
            selection: self.$composer.selectedVoice,
            preview: { voiceID in Task { await self.tts.previewVoice(voiceID) } },
            previewDisabled: self.tts.isSynthesizing
          )

          OpenRouterSpeechPickerButton(selectedVoice: self.$composer.selectedVoice)

          if let voice = VoiceCatalog.voice(forID: self.composer.selectedVoice) {
            HStack(spacing: 6) {
              ForEach(voice.traits.prefix(3), id: \.self) { trait in
                Text(trait.rawValue.capitalized)
                  .font(.caption2)
                  .padding(.horizontal, 8)
                  .padding(.vertical, 4)
                  .background(Capsule().fill(Color.secondary.opacity(0.15)))
              }
            }
          }

          Button {
            Task {
              await self.tts.previewVoice(self.composer.selectedVoice)
            }
          } label: {
            Label("Preview Voice", systemImage: "play.circle")
          }
          .buttonStyle(.bordered)
          .disabled(self.tts.isSynthesizing)
        }
      }
    }
  }

  /// Names the providers whose voice listing failed, so a provider that has
  /// no offline catalogue does not simply disappear from the picker.
  @ViewBuilder
  private var voiceListingFailureNotice: some View {
    if !self.tts.voiceListingErrors.isEmpty {
      let names = self.tts.voiceListingErrors.keys
        .map(\.displayName)
        .sorted()
        .joined(separator: ", ")
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
        VStack(alignment: .leading, spacing: 2) {
          Text("Could not load voices from \(names).")
            .font(.caption)
          Text("Any voices shown for them are from the last successful load.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Retry") {
          Task { await self.composer.loadAvailableVoices(from: self.tts, defaultVoice: self.settings.defaultTTSVoice) }
        }
        .buttonStyle(.link)
        .font(.caption)
      }
      .accessibilityElement(children: .combine)
    }
  }
}

/// Speed, pitch, SSML and output preferences for synthesis.
struct VoiceOutputControlsCard: View {
  @ObservedObject var composer: VoiceOutputComposer
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
    SpeakDensityCard(title: "Controls", systemImage: "slider.horizontal.3", tint: .green) {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Speed")
              .font(.subheadline)
            Spacer()
            Text(String(format: "%.2fx", self.settings.ttsSpeed))
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Slider(value: self.$settings.ttsSpeed, in: 0.5...2.0, step: 0.1)
            .accessibilityLabel("Speed")
            .accessibilityValue(String(format: "%.2fx", self.settings.ttsSpeed))
        }

        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Pitch")
              .font(.subheadline)
            Spacer()
            Text("\(self.settings.ttsPitch > 0 ? "+" : "")\(Int(self.settings.ttsPitch)) st")
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Slider(value: self.$settings.ttsPitch, in: -12...12, step: 1)
            .accessibilityLabel("Pitch")
            .accessibilityValue("\(Int(self.settings.ttsPitch)) semitones")
        }

        Divider()

        Toggle("Use SSML", isOn: self.$settings.ttsUseSSML)
          .help("Enable SSML for advanced voice control")

        if self.settings.ttsUseSSML {
          Button("SSML Helper") {
            self.composer.showingSSMLHelper = true
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }

        Toggle("Auto-play", isOn: self.$settings.ttsAutoPlay)
        Toggle("Save to recordings", isOn: self.$settings.ttsSaveToDirectory)
      }
    }
  }
}
