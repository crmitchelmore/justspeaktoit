import SpeakCore
import SwiftUI

/// The Voice Output settings tab: default voice, quality, export, favourites
/// and the TTS pronunciation dictionary.
struct VoiceOutputSettingsSection: View, AppSettingsBindingProviding {
  @EnvironmentObject var environment: AppEnvironment
  @EnvironmentObject var settings: AppSettings
  /// Voices only a keyed account lists — Mistral publishes no presets.
  @State private var accountListedVoices: [TTSVoice] = []

  private var usesRealtimeVoice: Bool {
    OpenAIRealtimeSpeech.voiceID(fromProviderVoiceID: settings.defaultTTSVoice) != nil
  }

  /// The Default Voice list: the offline catalogue plus whatever the stored
  /// keys' accounts list, so a Mistral voice can be made the default here and
  /// not only chosen ad hoc in Voice Output.
  private var defaultVoicePickerOptions: [TTSVoice] {
    VoiceCatalog.includingSelection(
      settings.defaultTTSVoice,
      in: VoiceCatalog.allVoices + accountListedVoices
    )
  }

  var body: some View {
    SpeakDensitySettingsSection(density: settings.visualDensity) {
      SettingsCard(title: "Default Voice", systemImage: "speaker.wave.3", tint: Color.brandLagoonDeep) {
        VStack(alignment: .leading, spacing: 12) {
          VStack(alignment: .leading, spacing: 8) {
            VoicePicker(
              voices: defaultVoicePickerOptions,
              storedAPIKeyIdentifiers: settings.trackedAPIKeyIdentifiers,
              selection: settingsBinding(\AppSettings.defaultTTSVoice)
            )
            .speakTooltip("Choose your preferred voice for text-to-speech synthesis")

            OpenRouterSpeechPickerButton(selectedVoice: settingsBinding(\AppSettings.defaultTTSVoice))

            Text("Your default voice for converting text to speech")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          LongListPicker(
            title: "Language", items: VoiceOutputLanguageCatalog.options,
            id: { $0.id }, selection: settingsBinding(\AppSettings.ttsLanguageIdentifier),
            searchText: { [$0.displayName, $0.id] },
            row: { option in
            Text(option.displayName)
          })
          .pickerStyle(.menu)

          if TTSProvider.from(voiceID: settings.defaultTTSVoice) == .mistral {
            Picker("Mistral Model", selection: settingsBinding(\AppSettings.mistralTTSModel)) {
              ForEach(MistralTTSCatalog.models) { model in
                Text(model.displayName).tag(model)
              }
            }
            .pickerStyle(.menu)
            if settings.mistralTTSModel == .voxtralMiniTTS3 {
              Text("Voxtral TTS 3 is a public preview. Use [emotion=happy] or [pace=slow] in your text "
                + "to direct delivery.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text("Speed, pitch and SSML controls are unsupported by Mistral.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          if TTSProvider.from(voiceID: settings.defaultTTSVoice) == .openai,
            OpenAIRealtimeSpeech.voiceID(fromProviderVoiceID: settings.defaultTTSVoice) == nil,
            let retirement = OpenAITTSModel.standard.retirement {
            Text("OpenAI speech models: \(retirement.notice)")
              .font(.caption)
              .foregroundStyle(.orange)
          }

          if TTSProvider.from(voiceID: settings.defaultTTSVoice) == .soniox {
            Picker("Soniox Region", selection: settingsBinding(\AppSettings.sonioxTTSRegion)) {
              ForEach(SonioxTTSRegion.allCases) { region in
                Text(region.displayName).tag(region)
              }
            }
            .pickerStyle(.segmented)
          }
        }
      }
      .speakTooltip("Select which voice to use by default when generating speech from text.")
      .task {
        accountListedVoices = await environment.tts.accountListedVoices()
      }

      SettingsCard(title: "Audio Quality & Performance", systemImage: "waveform.circle", tint: Color.green) {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 8) {
            Picker("Quality", selection: settingsBinding(\AppSettings.ttsQuality)) {
              ForEach(TTSQuality.allCases) { quality in
                Text(quality.displayName).tag(quality)
              }
            }
            .pickerStyle(.segmented)

            Text(settings.ttsQuality.description)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .speakTooltip("Fast uses low-latency models, Best Quality uses HD models")

          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Speed")
              Spacer()
              Text(String(format: "%.2fx", settings.ttsSpeed))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Slider(
              value: settingsBinding(\AppSettings.ttsSpeed), in: usesRealtimeVoice ? 0.5...1.5 : 0.5...2.0, step: 0.1)
              .accessibilityLabel("Speed")
              .accessibilityValue(String(format: "%.2fx", settings.ttsSpeed))
              .speakTooltip("Adjust playback speed from 0.5x (slower) to 2.0x (faster)")
          }

          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Pitch")
              Spacer()
              Text("\(settings.ttsPitch > 0 ? "+" : "")\(Int(settings.ttsPitch)) semitones")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Slider(value: settingsBinding(\AppSettings.ttsPitch), in: -12...12, step: 1)
              .accessibilityLabel("Pitch")
              .accessibilityValue("\(Int(settings.ttsPitch)) semitones")
              .speakTooltip("Adjust voice pitch from -12 (lower) to +12 (higher) semitones")
          }
        }
      }
      .speakTooltip("Control audio quality, playback speed, and voice pitch for generated speech.")

      SettingsCard(title: "Output & Export", systemImage: "arrow.down.circle", tint: Color.brandAccentWarm) {
        VStack(alignment: .leading, spacing: 12) {
          VStack(alignment: .leading, spacing: 8) {
            Picker("File Format", selection: settingsBinding(\AppSettings.ttsOutputFormat)) {
              ForEach(AudioFormat.allCases) { format in
                Text(format.displayName).tag(format)
              }
            }
            .pickerStyle(.segmented)
            .disabled(usesRealtimeVoice)
            .speakTooltip("Choose the audio file format for exported speech")
            if usesRealtimeVoice {
              Text("OpenAI Realtime voices always save WAV.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          settingsToggle(
            "Auto-play after synthesis",
            isOn: settingsBinding(\AppSettings.ttsAutoPlay),
            tint: .brandAccentWarm
          )
          .speakTooltip("Automatically play audio after synthesis completes")

          settingsToggle(
            "Save to recordings directory",
            isOn: settingsBinding(\AppSettings.ttsSaveToDirectory),
            tint: .brandAccentWarm
          )
          .speakTooltip("Automatically save generated speech files to your recordings folder")

          settingsToggle(
            "Enable SSML support",
            isOn: settingsBinding(\AppSettings.ttsUseSSML),
            tint: .brandAccentWarm
          )
          .speakTooltip("Enable Speech Synthesis Markup Language for advanced voice control")
        }
      }
      .speakTooltip("Configure how generated speech is saved and played back.")

      SettingsCard(title: "Favorite Voices", systemImage: "star.fill", tint: Color.yellow) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Quick access to your preferred voices")
            .font(.caption)
            .foregroundStyle(.secondary)

          if settings.ttsFavoriteVoices.isEmpty {
            Text("No favorites yet. Add voices from the Voice Output view.")
              .font(.caption)
              .foregroundStyle(.tertiary)
              .padding(.vertical, 8)
          } else {
            ForEach(settings.ttsFavoriteVoices, id: \.self) { voiceID in
              if let voice = VoiceCatalog.voice(forID: voiceID) {
                HStack {
                  Text(voice.displayName)
                    .font(.subheadline)
                  Spacer()
                  Button {
                    settings.ttsFavoriteVoices.removeAll { $0 == voiceID }
                  } label: {
                    Image(systemName: "xmark.circle.fill")
                      .foregroundStyle(.secondary)
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel("Remove \(voice.displayName) from favourites")
                  .accessibilityIdentifier("ttsFavoriteVoiceRemove-\(voiceID)")
                }
                .padding(.vertical, 4)
              }
            }
          }
        }
      }
      .speakTooltip("Manage your favorite voices for quick access.")

      SettingsCard(title: "Pronunciation Dictionary", systemImage: "text.book.closed", tint: Color.brandAccent) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Custom pronunciations for words the TTS mispronounces")
            .font(.caption)
            .foregroundStyle(.secondary)

          if settings.ttsPronunciationDictionary.isEmpty {
            Text("No custom pronunciations. Add words that are commonly mispronounced.")
              .font(.caption)
              .foregroundStyle(.tertiary)
              .padding(.vertical, 8)
          } else {
            ForEach(Array(settings.ttsPronunciationDictionary.keys.sorted()), id: \.self) { word in
              if let pronunciation = settings.ttsPronunciationDictionary[word] {
                HStack {
                  Text(word)
                    .font(.subheadline.bold())
                  Text("→")
                    .foregroundStyle(.secondary)
                  Text(pronunciation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                  Spacer()
                  Button {
                    settings.ttsPronunciationDictionary.removeValue(forKey: word)
                  } label: {
                    Image(systemName: "xmark.circle.fill")
                      .foregroundStyle(.secondary)
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel("Remove pronunciation for \(word)")
                  .accessibilityIdentifier("ttsPronunciationRemove-\(word)")
                }
                .padding(.vertical, 4)
              }
            }
          }

          Divider()

          PronunciationEntryView(dictionary: Binding(
            get: { settings.ttsPronunciationDictionary },
            set: { settings.ttsPronunciationDictionary = $0 }
          ))
        }
      }
      .speakTooltip("Add custom pronunciations for words that TTS engines commonly mispronounce.")
    }
  }
}
