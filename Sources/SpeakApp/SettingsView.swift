import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
  case general
  case transcription
  case postProcessing
  case voiceOutput
  case pronunciation
  case apiKeys
  case shortcuts
  case permissions

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: return "General"
    case .transcription: return "Transcription"
    case .postProcessing: return "Post-processing"
    case .voiceOutput: return "Voice Output"
    case .pronunciation: return "Pronunciation"
    case .apiKeys: return "API Keys"
    case .shortcuts: return "Keyboard"
    case .permissions: return "Permissions"
    }
  }

  var systemImage: String {
    switch self {
    case .general: return "gearshape"
    case .transcription: return "waveform"
    case .postProcessing: return "wand.and.stars"
    case .voiceOutput: return "speaker.wave.3"
    case .pronunciation: return "character.book.closed"
    case .apiKeys: return "key.fill"
    case .shortcuts: return "keyboard"
    case .permissions: return "hand.raised.fill"
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var environment: AppEnvironment
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var audioDevices: AudioInputDeviceManager
  private static let localeOptions: [LocaleOption] = [
    LocaleOption(displayName: "English (United States)", identifier: "en_US"),
    LocaleOption(displayName: "English (United Kingdom)", identifier: "en_GB"),
    LocaleOption(displayName: "English (Australia)", identifier: "en_AU"),
    LocaleOption(displayName: "English (Canada)", identifier: "en_CA"),
    LocaleOption(displayName: "Spanish (Spain)", identifier: "es_ES"),
    LocaleOption(displayName: "Spanish (Mexico)", identifier: "es_MX"),
    LocaleOption(displayName: "French (France)", identifier: "fr_FR"),
    LocaleOption(displayName: "German (Germany)", identifier: "de_DE"),
    LocaleOption(displayName: "Hindi (India)", identifier: "hi_IN"),
    LocaleOption(displayName: "Japanese (Japan)", identifier: "ja_JP"),
    LocaleOption(displayName: "Korean (South Korea)", identifier: "ko_KR"),
    LocaleOption(displayName: "Portuguese (Brazil)", identifier: "pt_BR"),
    LocaleOption(displayName: "Portuguese (Portugal)", identifier: "pt_PT"),
    LocaleOption(displayName: "Chinese (Simplified)", identifier: "zh_CN"),
    LocaleOption(displayName: "Chinese (Traditional)", identifier: "zh_TW"),
    LocaleOption(displayName: "Arabic (Saudi Arabia)", identifier: "ar_SA"),
    LocaleOption(displayName: "Russian (Russia)", identifier: "ru_RU")
  ]

  let tab: SettingsTab
  @State private var newAPIKeyValue: String = ""
  @State private var apiKeyValidationState: ValidationViewState = .idle
  @State private var isDeletingRecordings: Bool = false
  @State private var transcriptionProviders: [TranscriptionProviderMetadata] = []
  @State private var providerAPIKeys: [String: String] = [:]
  @State private var providerValidationStates: [String: ValidationViewState] = [:]
  @State private var ttsProviderAPIKeys: [String: String] = [:]
  @State private var ttsProviderValidationStates: [String: ValidationViewState] = [:]
  @State private var showSystemPromptPreview = false
  @State private var systemPromptPreview = ""
  private let openRouterKeyIdentifier = "openrouter.apiKey"

  enum ValidationViewState {
    case idle
    case validating
    case finished(APIKeyValidationResult)
  }

  private var isOpenRouterKeyStored: Bool {
    settings.trackedAPIKeyIdentifiers.contains(openRouterKeyIdentifier)
  }

  private var isValidatingKey: Bool {
    if case .validating = apiKeyValidationState { return true }
    return false
  }

  private var overviewHeader: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center) {
        Image(systemName: "sparkles.rectangle.stack")
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .white.opacity(0.7))
          .font(.system(size: 34, weight: .semibold))
          .frame(width: 56, height: 56)
          .background(
            Color.orange.opacity(0.6),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

        VStack(alignment: .leading, spacing: 6) {
          Text("Tune Speak to match your flow")
            .font(.title2.bold())
            .foregroundStyle(.white)
          Text(
            "Choose recording modes, manage keys, and keep permissions in sync—all in one place."
          )
          .font(.callout)
          .foregroundStyle(.white.opacity(0.8))
        }
        Spacer()
      }

      HStack(spacing: 16) {
        overviewChip(
          title: "Mode", value: settings.transcriptionMode.displayName, systemImage: "waveform")
        overviewChip(
          title: "Post-processing",
          value: settings.postProcessingEnabled ? "Enabled" : "Disabled",
          systemImage: "wand.and.stars")
        overviewChip(
          title: "Output", value: settings.textOutputMethod.displayName,
          systemImage: "text.alignleft")
        overviewChip(
          title: "OpenRouter Key", value: isOpenRouterKeyStored ? "Stored" : "Missing",
          systemImage: isOpenRouterKeyStored ? "checkmark.seal.fill" : "key.fill")
      }
    }
    .padding(24)
    .background(
      LinearGradient(
        colors: [Color.orange, Color.orange.opacity(0.7)], startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .cornerRadius(24)
      .shadow(color: Color.orange.opacity(0.3), radius: 18, x: 0, y: 12)
    )
  }

  @ViewBuilder
  private var tabContent: some View {
    switch tab {
    case .general:
      generalSettings
    case .transcription:
      transcriptionSettings
    case .postProcessing:
      postProcessingSettings
    case .voiceOutput:
      voiceOutputSettings
    case .pronunciation:
      pronunciationSettings
    case .apiKeys:
      apiKeySettings
    case .shortcuts:
      keyboardSettings
    case .permissions:
      permissionsSettings
    }
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

  init(tab: SettingsTab = .general) {
    self.tab = tab
  }

  private func overviewChip(title: String, value: String, systemImage: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: systemImage)
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.white.opacity(0.8))
      Text(value)
        .font(.headline)
        .foregroundStyle(.white)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        overviewHeader
        tabContent
      }
      .padding(24)
      .frame(maxWidth: 1100, alignment: .center)
    }
    .background(
      LinearGradient(
        colors: [Color.orange.opacity(0.08), .clear], startPoint: .top, endPoint: .center))
    .task {
      transcriptionProviders = await TranscriptionProviderRegistry.shared.allProviders()
    }
  }

  private var generalSettings: some View {
    LazyVStack(spacing: 20) {
      SettingsCard(title: "Appearance", systemImage: "paintpalette", tint: Color.purple) {
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
        }
      }
      .speakTooltip("Set Speak's look to match your workspace with light, dark, or system themes.")

      SettingsCard(title: "Output", systemImage: "textformat.alt", tint: Color.blue) {
        VStack(alignment: .leading, spacing: 12) {
          Picker("Text Output", selection: settingsBinding(\AppSettings.textOutputMethod)) {
            ForEach(AppSettings.TextOutputMethod.allCases) { method in
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
          .speakTooltip("Decide how Speak returns transcripts—typed for you, placed on the clipboard, or saved for later.")

          VStack(alignment: .leading, spacing: 8) {
            settingsToggle(
              "Restore clipboard after paste",
              isOn: settingsBinding(\AppSettings.restoreClipboardAfterPaste),
              tint: .blue
            )
            .speakTooltip("After Speak pastes your transcript, we put your original clipboard content back automatically.")
            settingsToggle(
              "Show HUD during sessions",
              isOn: settingsBinding(\AppSettings.showHUDDuringSessions),
              tint: .blue
            )
            .speakTooltip("Display a small heads-up display so you always know when Speak is listening.")
            settingsToggle(
              "Show live transcript in HUD",
              isOn: settingsBinding(\AppSettings.showLiveTranscriptInHUD),
              tint: .blue
            )
            .speakTooltip("Show real-time transcription text in the HUD while recording.")
            settingsToggle(
              "Show status bar only",
              isOn: settingsBinding(\AppSettings.showStatusBarOnly),
              tint: .blue
            )
            .speakTooltip("Keep Speak tucked into the menu bar while still being ready when you need it.")
            settingsToggle(
              "Launch at login",
              isOn: settingsBinding(\AppSettings.runAtLogin),
              tint: .blue
            )
            .speakTooltip("Have Speak start alongside macOS so recording is always one shortcut away.")
          }
        }
      }
      .speakTooltip("Control how Speak delivers transcripts and how gently we touch your clipboard and interface.")

      SettingsCard(title: "Microphone", systemImage: "mic.circle", tint: Color.orange) {
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

          if let details = audioDevices.currentSelectionDetails {
            Text(details)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          HStack(spacing: 8) {
            Image(systemName: "waveform")
              .foregroundStyle(.orange)
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

      SettingsCard(title: "Housekeeping", systemImage: "tray.full", tint: Color.orange) {
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder")
              .foregroundStyle(.orange)
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

  private var transcriptionSettings: some View {
    LazyVStack(spacing: 20) {
      SettingsCard(title: "Transcription mode", systemImage: "waveform", tint: Color.teal) {
        VStack(alignment: .leading, spacing: 12) {
          Picker("Transcription Mode", selection: settingsBinding(\AppSettings.transcriptionMode)) {
            ForEach(AppSettings.TranscriptionMode.allCases) { mode in
              Text(mode.displayName).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
          )
          .speakTooltip("Pick the recording flow that best matches how you speak—continuous live captions or hold-to-talk batches.")

          Picker("Preferred Locale", selection: settingsBinding(\AppSettings.preferredLocaleIdentifier)) {
            ForEach(resolvedLocaleOptions) { option in
              Text(option.displayName).tag(option.identifier)
            }
          }
          .pickerStyle(.menu)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
          )
          .speakTooltip("Choose from supported locales so Speak uses the right accent while transcribing.")
        }
      }
      .speakTooltip("Choose which transcription flow Speak uses and the locale it should prefer.")

      SettingsCard(title: "Processing Speed", systemImage: "gauge.with.dots.needle.67percent", tint: Color.cyan) {
        let speedModeAvailable = settings.transcriptionMode == .liveNative
          && settings.liveTranscriptionModel.contains("streaming")

        VStack(alignment: .leading, spacing: 12) {
          Text("Auto-clean/format modes require a streaming live transcription model and disable post-processing.")
            .font(.callout)
            .foregroundStyle(.secondary)

          if !speedModeAvailable {
            Text("To enable these modes, select a streaming Live Model (e.g., Deepgram Nova-2 Streaming).")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          VStack(spacing: 8) {
            ForEach(AppSettings.SpeedMode.allCases) { mode in
              Button {
                settings.speedMode = mode
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: speedModeIcon(for: mode))
                    .font(.title3)
                    .foregroundStyle(settings.speedMode == mode ? .white : .cyan)
                    .frame(width: 24)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                      .font(.headline)
                      .foregroundStyle(settings.speedMode == mode ? .white : .primary)
                    Text(mode.description)
                      .font(.caption)
                      .foregroundStyle(settings.speedMode == mode ? .white.opacity(0.8) : .secondary)
                  }
                  Spacer()
                  if settings.speedMode == mode {
                    Image(systemName: "checkmark.circle.fill")
                      .foregroundStyle(.white)
                  }
                }
                .padding(12)
                .background(
                  RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(settings.speedMode == mode ? Color.cyan : Color(nsColor: .controlBackgroundColor))
                )
              }
              .buttonStyle(.plain)
              .disabled(mode != .instant && !speedModeAvailable)
              .opacity(mode != .instant && !speedModeAvailable ? 0.6 : 1.0)
            }
          }
        }
      }
      .speakTooltip("Control the trade-off between speed and AI-powered text cleanup.")

      SettingsCard(title: "Recording buffer", systemImage: "waveform.path.ecg", tint: Color.cyan) {
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

      SettingsCard(title: "Silence detection", systemImage: "waveform.slash", tint: Color.orange) {
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
              .speakTooltip("How long to wait in silence before auto-stopping.")
            }
          }
        }
      }
      .speakTooltip("Configure automatic recording stop based on silence detection.")

      SettingsCard(title: "Live transcription", systemImage: "mic.fill", tint: Color.indigo) {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
              .foregroundStyle(.indigo)
              .imageScale(.small)
            Text("Fastest - Real-time Response")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.indigo)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(
            Capsule()
              .fill(Color.indigo.opacity(0.12))
          )

          Text("Model used while recording. Provides instant feedback as you speak.")
            .font(.caption)
            .foregroundStyle(.secondary)
          ModelPicker(
            title: "Live Model",
            help: "Choose between on-device (Apple) or streaming (Deepgram) transcription.",
            options: ModelCatalog.liveTranscription,
            value: settingsBinding(\AppSettings.liveTranscriptionModel)
          )
        }
      }
      .speakTooltip("Pick the model that transcribes as you speak during live recording.")

      SettingsCard(
        title: "Batch transcription", systemImage: "folder.badge.clock", tint: Color.cyan
      ) {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 8) {
            Image(systemName: "star.fill")
              .foregroundStyle(.cyan)
              .imageScale(.small)
            Text("Best Quality - Most Accurate")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.cyan)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(
            Capsule()
              .fill(Color.cyan.opacity(0.12))
          )

          Text("Model used when the recording is uploaded after it finishes. Delivers the highest accuracy.")
            .font(.caption)
            .foregroundStyle(.secondary)
          ModelPicker(
            title: "Batch Model",
            help: "Remote transcription runs after recording stops for maximum accuracy.",
            options: ModelCatalog.batchTranscription,
            value: settingsBinding(\AppSettings.batchTranscriptionModel)
          )
        }
      }
      .speakTooltip("Tell Speak which cloud transcription model should polish the full recording.")
    }
  }

  private var resolvedLocaleOptions: [LocaleOption] {
    var options = Self.localeOptions
    let current = settings.preferredLocaleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !current.isEmpty else { return options }
    if !options.contains(where: { $0.identifier == current }) {
      let display = localeDisplayName(for: current)
      options.append(LocaleOption(displayName: display, identifier: current))
    }
    return options
  }

  private func localeDisplayName(for identifier: String) -> String {
    let locale = Locale(identifier: identifier)
    if let localized = locale.localizedString(forIdentifier: identifier) {
      return localized.capitalized
    }
    if let localized = Locale.current.localizedString(forIdentifier: identifier) {
      return localized.capitalized
    }
    return identifier
  }


  private var postProcessingSettings: some View {
    LazyVStack(spacing: 20) {
      SettingsCard(title: "Cleanup", systemImage: "wand.and.stars", tint: Color.pink) {
        VStack(alignment: .leading, spacing: 12) {
          settingsToggle(
            "Enable Post-processing",
            isOn: settingsBinding(\AppSettings.postProcessingEnabled),
            tint: .pink
          )
          .disabled(settings.speedMode != .instant)
          .speakTooltip("Let Speak clean and enhance transcripts automatically before they reach your clipboard.")

          if settings.speedMode != .instant {
            Text("Post-processing is disabled while Processing Speed is set to \(settings.speedMode.displayName).")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          VStack(alignment: .leading, spacing: 8) {
            Picker("Output Language", selection: settingsBinding(\AppSettings.postProcessingOutputLanguage)) {
              Text("English").tag("English")
              Text("Spanish").tag("Spanish")
              Text("French").tag("French")
              Text("German").tag("German")
              Text("Italian").tag("Italian")
              Text("Portuguese").tag("Portuguese")
              Text("Chinese").tag("Chinese")
              Text("Japanese").tag("Japanese")
              Text("Korean").tag("Korean")
              Text("Russian").tag("Russian")
              Text("Arabic").tag("Arabic")
              Text("Hindi").tag("Hindi")
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            )
            .speakTooltip("Let Speak know which language you want your polished transcript delivered in.")
            .onChange(of: settings.postProcessingOutputLanguage) { _, _ in
              if showSystemPromptPreview {
                generateSystemPromptPreview()
              }
            }

            Text("The language that the transcription will be output in.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          ModelPicker(
            title: "Post-processing Model",
            help: "We clean up the transcript before delivery using this model.",
            options: ModelCatalog.postProcessing,
            value: settingsBinding(\AppSettings.postProcessingModel)
          )

          VStack(alignment: .leading) {
            HStack {
              Text("Temperature")
              Spacer()
              Text(
                settings.postProcessingTemperature,
                format: .number.precision(.fractionLength(2))
              )
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            }
            Slider(
              value: settingsBinding(\AppSettings.postProcessingTemperature), in: 0...1, step: 0.05)
            .speakTooltip("Lower values stay close to your words; higher values let Speak be more creative.")
          }
        }
      }
      .speakTooltip("Choose how Speak cleans up transcripts—from languages to creativity and custom prompts.")

      SettingsCard(title: "System prompt", systemImage: "quote.bubble", tint: Color.mint) {
        VStack(alignment: .leading, spacing: 8) {
          Text("The system prompt guides how the LLM cleans up your transcript.")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextEditor(text: settingsBinding(\AppSettings.postProcessingSystemPrompt))
            .font(.body.monospaced())
            .frame(minHeight: 200)
            .overlay(
              RoundedRectangle(cornerRadius: 12)
                .stroke(Color.mint.opacity(0.2), lineWidth: 1)
            )
            .onChange(of: settings.postProcessingSystemPrompt) { _, _ in
              if showSystemPromptPreview {
                generateSystemPromptPreview()
              }
            }
        }
      }
      .speakTooltip("Guide the cleanup model with your own instructions for tone and formatting.")

      SettingsCard(title: "System-Generated Parts", systemImage: "gearshape.2", tint: Color.indigo) {
        VStack(alignment: .leading, spacing: 16) {
          Text("Control which system-generated instructions are added to the prompt.")
            .font(.caption)
            .foregroundStyle(.secondary)

          VStack(alignment: .leading, spacing: 12) {
            settingsToggle(
              "Include Personal Lexicon Directives",
              isOn: settingsBinding(\AppSettings.postProcessingIncludeLexiconDirectives),
              tint: .indigo
            )
            .onChange(of: settings.postProcessingIncludeLexiconDirectives) { _, _ in
              generateSystemPromptPreview()
            }
            Text("Automatically applies your personal corrections and name normalizations to the transcript.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.leading, 28)

            Divider()

            settingsToggle(
              "Include Context Tags",
              isOn: settingsBinding(\AppSettings.postProcessingIncludeContextTags),
              tint: .indigo
            )
            .onChange(of: settings.postProcessingIncludeContextTags) { _, _ in
              generateSystemPromptPreview()
            }
            Text("Adds context tags to help the model understand the setting and adjust output accordingly.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.leading, 28)

            Divider()

            settingsToggle(
              "Include Final Processing Instruction",
              isOn: settingsBinding(\AppSettings.postProcessingIncludeFinalInstruction),
              tint: .indigo
            )
            .onChange(of: settings.postProcessingIncludeFinalInstruction) { _, _ in
              generateSystemPromptPreview()
            }
            Text("Adds a hardcoded reminder: \"Return only the processed text and nothing else. The following message is a raw transcript:\"")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.leading, 28)
          }

          Divider()

          VStack(alignment: .leading, spacing: 8) {
            Button {
              showSystemPromptPreview.toggle()
              if showSystemPromptPreview {
                DispatchQueue.main.async {
                  generateSystemPromptPreview()
                }
              }
            } label: {
              HStack {
                Image(systemName: showSystemPromptPreview ? "eye.slash" : "eye")
                Text(showSystemPromptPreview ? "Hide Current Prompt" : "Show Current Prompt")
              }
            }
            .buttonStyle(.bordered)

            if showSystemPromptPreview {
              VStack(alignment: .leading, spacing: 8) {
                Text("Current System Prompt Preview:")
                  .font(.caption.bold())
                  .foregroundStyle(.secondary)

                ScrollView {
                  Text(systemPromptPreview)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .scrollIndicators(.visible)
                .frame(minHeight: 200, maxHeight: 420)
                .background(
                  RoundedRectangle(cornerRadius: 8)
                    .fill(Color.indigo.opacity(0.05))
                )

                Text("Scroll to view the full prompt.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                .overlay(
                  RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.indigo.opacity(0.2), lineWidth: 1)
                )
              }
            }
          }
        }
      }
      .speakTooltip("Fine-tune what system-generated instructions are sent to the post-processing model.")
    }
  }

  private var voiceOutputSettings: some View {
    LazyVStack(spacing: 20) {
      SettingsCard(title: "Default Voice", systemImage: "speaker.wave.3", tint: Color.blue) {
        VStack(alignment: .leading, spacing: 12) {
          VStack(alignment: .leading, spacing: 8) {
            Picker("Voice", selection: settingsBinding(\AppSettings.defaultTTSVoice)) {
              ForEach(VoiceCatalog.allVoices) { voice in
                Text(voice.displayName).tag(voice.id)
              }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            )
            .speakTooltip("Choose your preferred voice for text-to-speech synthesis")

            Text("Your default voice for converting text to speech")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .speakTooltip("Select which voice to use by default when generating speech from text.")

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
            Slider(value: settingsBinding(\AppSettings.ttsSpeed), in: 0.5...2.0, step: 0.1)
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
              .speakTooltip("Adjust voice pitch from -12 (lower) to +12 (higher) semitones")
          }
        }
      }
      .speakTooltip("Control audio quality, playback speed, and voice pitch for generated speech.")

      SettingsCard(title: "Output & Export", systemImage: "arrow.down.circle", tint: Color.orange) {
        VStack(alignment: .leading, spacing: 12) {
          VStack(alignment: .leading, spacing: 8) {
            Picker("File Format", selection: settingsBinding(\AppSettings.ttsOutputFormat)) {
              ForEach(AudioFormat.allCases) { format in
                Text(format.displayName).tag(format)
              }
            }
            .pickerStyle(.segmented)
            .speakTooltip("Choose the audio file format for exported speech")
          }

          settingsToggle(
            "Auto-play after synthesis",
            isOn: settingsBinding(\AppSettings.ttsAutoPlay),
            tint: .orange
          )
          .speakTooltip("Automatically play audio after synthesis completes")

          settingsToggle(
            "Save to recordings directory",
            isOn: settingsBinding(\AppSettings.ttsSaveToDirectory),
            tint: .orange
          )
          .speakTooltip("Automatically save generated speech files to your recordings folder")

          settingsToggle(
            "Enable SSML support",
            isOn: settingsBinding(\AppSettings.ttsUseSSML),
            tint: .orange
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
                }
                .padding(.vertical, 4)
              }
            }
          }
        }
      }
      .speakTooltip("Manage your favorite voices for quick access.")

      SettingsCard(title: "Pronunciation Dictionary", systemImage: "text.book.closed", tint: Color.purple) {
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

  private var pronunciationSettings: some View {
    PronunciationDictionaryView()
      .environmentObject(environment.pronunciationManager)
  }

  private var apiKeySettings: some View {
    LazyVStack(spacing: 20) {
      // OpenRouter (Legacy)
      apiKeyCard(
        title: "OpenRouter",
        systemImage: "network",
        tint: .green,
        statusIcon: isOpenRouterKeyStored ? "checkmark.seal.fill" : "key.fill",
        statusTint: .green,
        isStored: isOpenRouterKeyStored,
        descriptionText: "Stored securely in your macOS Keychain. We only use it when calling OpenRouter.",
        keyFieldLabel: "OpenRouter API Key",
        keyBinding: $newAPIKeyValue,
        onSave: saveAPIKey,
        onValidate: isOpenRouterKeyStored ? checkOpenRouterKeyValidity : nil,
        onRemove: isOpenRouterKeyStored ? removeOpenRouterKey : nil,
        isSaveDisabled: isValidatingKey
          || newAPIKeyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        isValidateDisabled: isValidatingKey,
        isRemoveDisabled: isValidatingKey,
        validationState: apiKeyValidationState,
        tooltip: "Securely store and validate the OpenRouter key Speak uses for advanced models.",
        saveButtonTitle: isOpenRouterKeyStored ? "Replace Key" : "Save Key",
        saveTooltip: "Store this OpenRouter key safely in your macOS Keychain for Speak to use when needed.",
        validateButtonTitle: "Check Validity",
        validateTooltip: "Make sure your saved key still works before you rely on it in a session.",
        removeButtonTitle: "Remove Key",
        removeTooltip: "Forget this key from Speak and your Keychain if you no longer need it.",
        link: nil,
        linkLabel: nil
      )

      // Transcription Providers (Dynamic)
      ForEach(transcriptionProviders) { provider in
        providerAPIKeyCard(for: provider)
          .id("transcription-\(provider.id)")
      }

      // TTS Providers
      ForEach([TTSProvider.elevenlabs, .openai, .azure, .deepgram]) { provider in
        ttsProviderAPIKeyCard(for: provider)
          .id("tts-\(provider.id)")
      }
    }
  }

  private func providerAPIKeyCard(for provider: TranscriptionProviderMetadata) -> some View {
    let isStored = settings.trackedAPIKeyIdentifiers.contains(provider.apiKeyIdentifier)
    let tintColor = colorFromString(provider.tintColor)
    let validationState = providerValidationStates[provider.id] ?? .idle
    let inFlight = isValidationInFlight(validationState)
    let saveDisabled = inFlight
      || (providerAPIKeys[provider.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let validateDisabled = inFlight || !isStored
    let removeDisabled = inFlight

    return apiKeyCard(
      title: "\(provider.displayName) (Transcription)",
      systemImage: provider.systemImage,
      tint: tintColor,
      statusIcon: isStored ? "checkmark.seal.fill" : "key.fill",
      statusTint: tintColor,
      isStored: isStored,
      descriptionText: "Stored securely in your macOS Keychain. Used only for \(provider.displayName) transcription.",
      keyFieldLabel: provider.apiKeyLabel,
      keyBinding: binding(for: provider.id),
      onSave: { saveProviderAPIKey(provider) },
      onValidate: isStored ? { checkProviderKeyValidity(provider) } : nil,
      onRemove: isStored ? { removeProviderAPIKey(provider) } : nil,
      isSaveDisabled: saveDisabled,
      isValidateDisabled: validateDisabled,
      isRemoveDisabled: removeDisabled,
      validationState: validationState,
      tooltip: "Manage your \(provider.displayName) API key securely without leaving Speak.",
      saveButtonTitle: isStored ? "Replace Key" : "Save Key",
      saveTooltip: "Securely store your \(provider.displayName) key so Speak can contact the service when needed.",
      validateButtonTitle: "Check Validity",
      validateTooltip: "Confirm that your \(provider.displayName) key is still valid before a big session.",
      removeButtonTitle: "Remove Key",
      removeTooltip: "Forget this service key from Speak and your Keychain when you no longer use it.",
      link: provider.website.isEmpty ? nil : URL(string: provider.website),
      linkLabel: provider.website.isEmpty ? nil : "Get API Key"
    )
  }

  private func ttsProviderAPIKeyCard(for provider: TTSProvider) -> some View {
    let isStored = settings.trackedAPIKeyIdentifiers.contains(provider.apiKeyIdentifier)
    let validationState = ttsProviderValidationStates[provider.rawValue] ?? .idle
    let inFlight = isValidationInFlight(validationState)
    let saveDisabled = inFlight
      || (ttsProviderAPIKeys[provider.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let validateDisabled = inFlight || !isStored
    let removeDisabled = inFlight

    let tintColor: Color = {
      switch provider {
      case .elevenlabs: return .purple
      case .openai: return .green
      case .azure: return .blue
      case .deepgram: return .orange
      case .system: return .gray
      }
    }()
    let systemImage: String = {
      switch provider {
      case .elevenlabs: return "waveform.circle"
      case .openai: return "brain"
      case .azure: return "cloud"
      case .deepgram: return "bolt.circle"
      case .system: return "speaker.wave.2"
      }
    }()
    let website: String = {
      switch provider {
      case .elevenlabs: return "https://elevenlabs.io"
      case .openai: return "https://platform.openai.com"
      case .azure: return "https://azure.microsoft.com/en-us/services/cognitive-services/text-to-speech/"
      case .deepgram: return "https://deepgram.com"
      case .system: return ""
      }
    }()

    return apiKeyCard(
      title: "\(provider.displayName) (TTS)",
      systemImage: systemImage,
      tint: tintColor,
      statusIcon: isStored ? "checkmark.seal.fill" : "key.fill",
      statusTint: tintColor,
      isStored: isStored,
      descriptionText: provider == .azure
        ? "For Azure Text-to-Speech, use format: 'your-api-key:your-region' (e.g., 'abc123:eastus')"
        : "Stored securely in your macOS Keychain. Used only for \(provider.displayName) text-to-speech voice synthesis.",
      keyFieldLabel: "\(provider.displayName) TTS API Key",
      keyBinding: ttsBinding(for: provider.rawValue),
      onSave: { saveTTSProviderAPIKey(provider) },
      onValidate: isStored ? { checkTTSProviderKeyValidity(provider) } : nil,
      onRemove: isStored ? { removeTTSProviderAPIKey(provider) } : nil,
      isSaveDisabled: saveDisabled,
      isValidateDisabled: validateDisabled,
      isRemoveDisabled: removeDisabled,
      validationState: validationState,
      tooltip: "Manage your \(provider.displayName) API key for text-to-speech synthesis.",
      saveButtonTitle: isStored ? "Replace Key" : "Save Key",
      saveTooltip: "Securely store your \(provider.displayName) key for voice synthesis.",
      validateButtonTitle: "Check Validity",
      validateTooltip: "Confirm that your \(provider.displayName) key is still valid.",
      removeButtonTitle: "Remove Key",
      removeTooltip: "Forget this key from Speak and your Keychain.",
      link: website.isEmpty ? nil : URL(string: website),
      linkLabel: website.isEmpty ? nil : "Get API Key"
    )
  }

  private func apiKeyCard(
    title: String,
    systemImage: String,
    tint: Color,
    statusIcon: String,
    statusTint: Color,
    isStored: Bool,
    descriptionText: String,
    keyFieldLabel: String,
    keyBinding: Binding<String>,
    onSave: @escaping () -> Void,
    onValidate: (() -> Void)?,
    onRemove: (() -> Void)?,
    isSaveDisabled: Bool,
    isValidateDisabled: Bool,
    isRemoveDisabled: Bool,
    validationState: ValidationViewState,
    tooltip: String,
    saveButtonTitle: String,
    saveTooltip: String,
    validateButtonTitle: String,
    validateTooltip: String,
    removeButtonTitle: String,
    removeTooltip: String,
    link: URL?,
    linkLabel: String?,
    statusLabel: String = "Status"
  ) -> some View {
    SettingsCard(title: title, systemImage: systemImage, tint: tint) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .center, spacing: 12) {
          Label(statusLabel, systemImage: statusIcon)
            .foregroundStyle(isStored ? statusTint : Color.secondary)
            .labelStyle(.titleAndIcon)
          statusBadge(isStored: isStored, color: statusTint)
        }

        if let link, let linkLabel {
          Link(destination: link) {
            Label(linkLabel, systemImage: "arrow.up.forward.square")
              .font(.caption)
          }
          .speakTooltip("Open \(title)'s site to create or manage your API key in your browser.")
        }

        SecureField(keyFieldLabel, text: keyBinding)
          .textContentType(.password)
          .privacySensitive()
          .textFieldStyle(.roundedBorder)
          .speakTooltip("Paste your \(title) key exactly as issued; Speak stores it securely in your Keychain.")

        Text(descriptionText)
          .font(.caption)
          .foregroundStyle(.secondary)

        HStack(spacing: 12) {
          Button(action: onSave) {
            if isValidationInFlight(validationState) {
              ProgressView()
                .controlSize(.small)
            } else {
              Label(saveButtonTitle, systemImage: "arrow.down.circle")
            }
          }
          .disabled(isSaveDisabled)
          .buttonStyle(.borderedProminent)
          .tint(tint)
          .speakTooltip(saveTooltip)

          if let onValidate, isStored {
            Button(action: onValidate) {
              if isValidationInFlight(validationState) {
                ProgressView()
                  .controlSize(.small)
              } else {
                Label(validateButtonTitle, systemImage: "checkmark.shield")
              }
            }
            .disabled(isValidateDisabled)
            .buttonStyle(.bordered)
            .speakTooltip(validateTooltip)
          }

          if let onRemove, isStored {
            Button(removeButtonTitle, role: .destructive, action: onRemove)
              .disabled(isRemoveDisabled)
              .speakTooltip(removeTooltip)
          }
        }

        validationStatusView(for: validationState)
        validationDebugDetails(for: validationState)
      }
    }
    .speakTooltip(tooltip)
  }

  private func binding(for providerID: String) -> Binding<String> {
    Binding(
      get: { providerAPIKeys[providerID] ?? "" },
      set: { providerAPIKeys[providerID] = $0 }
    )
  }

  private func statusBadge(isStored: Bool, color: Color) -> some View {
    let text = isStored ? "Saved" : "Not Set"
    let displayColor = isStored ? color : Color.secondary
    return Text(text.uppercased())
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        Capsule()
          .fill(displayColor.opacity(0.15))
      )
      .foregroundStyle(displayColor)
  }

  private func colorFromString(_ name: String) -> Color {
    switch name.lowercased() {
    case "green": return .green
    case "blue": return .blue
    case "purple": return .purple
    case "orange": return .orange
    case "red": return .red
    case "pink": return .pink
    case "yellow": return .yellow
    case "cyan": return .cyan
    case "indigo": return .indigo
    case "mint": return .mint
    case "teal": return .teal
    default: return .accentColor
    }
  }

  private func checkProviderKeyValidity(_ provider: TranscriptionProviderMetadata) {
    providerValidationStates[provider.id] = .validating

    Task {
      let registry = TranscriptionProviderRegistry.shared
      guard let providerInstance = await registry.provider(withID: provider.id) else {
        await MainActor.run {
          providerValidationStates[provider.id] =
            .finished(.failure(message: "Provider not found"))
        }
        return
      }

      // Get the stored key
      guard let storedKey = try? await environment.secureStorage.secret(identifier: provider.apiKeyIdentifier) else {
        await MainActor.run {
          providerValidationStates[provider.id] =
            .finished(.failure(message: "API key not found in Keychain"))
        }
        return
      }

      let result = await providerInstance.validateAPIKey(storedKey)

      await MainActor.run {
        providerValidationStates[provider.id] = .finished(result)
      }
    }
  }

  private func saveProviderAPIKey(_ provider: TranscriptionProviderMetadata) {
    guard let value = providerAPIKeys[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return }

    providerValidationStates[provider.id] = .validating

    Task {
      let registry = TranscriptionProviderRegistry.shared
      guard let providerInstance = await registry.provider(withID: provider.id) else {
        await MainActor.run {
          providerValidationStates[provider.id] =
            .finished(.failure(message: "Provider not found"))
        }
        return
      }

      let validation = await providerInstance.validateAPIKey(value)

      switch validation.outcome {
      case .success:
        do {
          try await environment.secureStorage.storeSecret(
            value,
            identifier: provider.apiKeyIdentifier,
            label: provider.apiKeyLabel
          )

          let result = validation.updatingOutcome(
            .success(message: "API key saved and validated successfully")
          )

          await MainActor.run {
            providerAPIKeys[provider.id] = ""
            providerValidationStates[provider.id] = .finished(result)
          }
        } catch {
          let failure = APIKeyValidationResult.failure(
            message: "Failed to store key: \(error.localizedDescription)",
            debug: validation.debug
          )
          await MainActor.run {
            providerValidationStates[provider.id] = .finished(failure)
          }
        }
      case .failure:
        await MainActor.run {
          providerValidationStates[provider.id] = .finished(validation)
        }
      }
    }
  }

  private func removeProviderAPIKey(_ provider: TranscriptionProviderMetadata) {
    Task {
      do {
        try await environment.secureStorage.removeSecret(identifier: provider.apiKeyIdentifier)
        await MainActor.run {
          providerAPIKeys[provider.id] = ""
          providerValidationStates[provider.id] = .idle
        }
      } catch {
        // Handle error silently
      }
    }
  }

  // MARK: - TTS Provider API Key Management

  private func ttsBinding(for providerID: String) -> Binding<String> {
    Binding(
      get: { ttsProviderAPIKeys[providerID] ?? "" },
      set: { ttsProviderAPIKeys[providerID] = $0 }
    )
  }

  private func saveTTSProviderAPIKey(_ provider: TTSProvider) {
    guard let value = ttsProviderAPIKeys[provider.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return }

    ttsProviderValidationStates[provider.rawValue] = .validating

    Task {
      let client = environment.tts.clients[provider]
      guard let client = client else {
        await MainActor.run {
          ttsProviderValidationStates[provider.rawValue] =
            .finished(.failure(message: "TTS provider not found"))
        }
        return
      }

      let validation = await client.validateAPIKey(value)

      switch validation.outcome {
      case .success:
        do {
          try await environment.secureStorage.storeSecret(
            value,
            identifier: provider.apiKeyIdentifier,
            label: "\(provider.displayName) TTS API Key"
          )

          let result = validation.updatingOutcome(
            .success(message: "API key saved and validated successfully")
          )

          await MainActor.run {
            ttsProviderAPIKeys[provider.rawValue] = ""
            ttsProviderValidationStates[provider.rawValue] = .finished(result)
          }
        } catch {
          let failure = APIKeyValidationResult.failure(
            message: "Failed to store key: \(error.localizedDescription)",
            debug: validation.debug
          )
          await MainActor.run {
            ttsProviderValidationStates[provider.rawValue] = .finished(failure)
          }
        }
      case .failure:
        await MainActor.run {
          ttsProviderValidationStates[provider.rawValue] = .finished(validation)
        }
      }
    }
  }

  private func checkTTSProviderKeyValidity(_ provider: TTSProvider) {
    ttsProviderValidationStates[provider.rawValue] = .validating

    Task {
      let client = environment.tts.clients[provider]
      guard let client = client else {
        await MainActor.run {
          ttsProviderValidationStates[provider.rawValue] =
            .finished(.failure(message: "TTS provider not found"))
        }
        return
      }

      guard let storedKey = try? await environment.secureStorage.secret(identifier: provider.apiKeyIdentifier) else {
        await MainActor.run {
          ttsProviderValidationStates[provider.rawValue] =
            .finished(.failure(message: "API key not found in Keychain"))
        }
        return
      }

      let result = await client.validateAPIKey(storedKey)

      await MainActor.run {
        ttsProviderValidationStates[provider.rawValue] = .finished(result)
      }
    }
  }

  private func removeTTSProviderAPIKey(_ provider: TTSProvider) {
    Task {
      do {
        try await environment.secureStorage.removeSecret(identifier: provider.apiKeyIdentifier)
        await MainActor.run {
          ttsProviderAPIKeys[provider.rawValue] = ""
          ttsProviderValidationStates[provider.rawValue] = .idle
        }
      } catch {
        // Handle error silently
      }
    }
  }

  private func checkOpenRouterKeyValidity() {
    apiKeyValidationState = .validating

    Task {
      do {
        let storedKey = try await environment.secureStorage.secret(identifier: openRouterKeyIdentifier)
        let result = await environment.openRouter.validateAPIKey(storedKey)

        await MainActor.run {
          apiKeyValidationState = .finished(result)
        }
      } catch {
        await MainActor.run {
          apiKeyValidationState = .finished(
            .failure(message: error.localizedDescription)
          )
        }
      }
    }
  }

  private func removeOpenRouterKey() {
    Task {
      do {
        try await environment.secureStorage.removeSecret(identifier: openRouterKeyIdentifier)
        await MainActor.run {
          apiKeyValidationState = .idle
          newAPIKeyValue = ""
        }
      } catch {
        await MainActor.run {
          apiKeyValidationState = .finished(
            .failure(message: error.localizedDescription)
          )
        }
      }
    }
  }

  @ViewBuilder
  private func validationStatusView(
    for state: ValidationViewState,
    successFallback: String = "Key saved and validated"
  ) -> some View {
    switch state {
    case .idle:
      EmptyView()
    case .validating:
      Text("Validating key…")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .finished(let result):
      switch result.outcome {
      case .success(let message):
        Label(message.isEmpty ? successFallback : message, systemImage: "checkmark.seal")
          .font(.caption)
          .foregroundStyle(.green)
      case .failure(let message):
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder
  private func validationDebugDetails(for state: ValidationViewState) -> some View {
    if case .finished(let result) = state, let debug = result.debug {
      Divider()
        .padding(.vertical, 4)
      APIKeyValidationDebugDetailsView(debug: debug)
    }
  }

  private func isValidationInFlight(_ state: ValidationViewState) -> Bool {
    if case .validating = state { return true }
    return false
  }

  private var keyboardSettings: some View {
    VStack(spacing: 20) {
      hotKeySettings
      ShortcutsSettingsView(shortcutManager: environment.shortcuts)
    }
  }

  private var hotKeySettings: some View {
    LazyVStack(spacing: 20) {
      SettingsCard(title: "Activation", systemImage: "command.square", tint: Color.yellow) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Choose how the Fn key controls recording.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Picker("Activation", selection: settingsBinding(\AppSettings.hotKeyActivationStyle)) {
            ForEach(AppSettings.HotKeyActivationStyle.allCases) { style in
              Text(style.displayName).tag(style)
            }
          }
          .pickerStyle(.segmented)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
          )
          .speakTooltip("Decide whether you press, hold, or double-tap the Fn key to start a session.")
        }
      }
      .speakTooltip("Choose how the Fn key behaves when you start and stop recordings.")

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

  private var permissionsSettings: some View {
    LazyVStack(spacing: 20) {
      SettingsCard(title: "System permissions", systemImage: "lock.shield", tint: Color.red) {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(PermissionType.allCases) { permission in
            let status = environment.permissions.status(for: permission)
            HStack(spacing: 12) {
              Label(permission.displayName, systemImage: permission.systemIconName)
              Spacer()
              Text(statusLabel(for: status))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor(status).opacity(0.15), in: Capsule())
                .foregroundStyle(statusColor(status))
              Button("Request") {
                Task { await environment.permissions.request(permission) }
              }
              .buttonStyle(.bordered)
              .speakTooltip("Ask macOS to prompt again for \(permission.displayName) access.")
            }
          }

          Button("Refresh Statuses") {
            environment.permissions.refreshAll()
          }
          .buttonStyle(.borderedProminent)
          .speakTooltip("Re-check what the system currently allows without leaving Speak.")
        }
      }
      .speakTooltip("Review and refresh the macOS permissions Speak depends on.")
    }
  }

  private func statusLabel(for status: PermissionStatus) -> String {
    switch status {
    case .granted: return "Granted"
    case .denied: return "Denied"
    case .restricted: return "Restricted"
    case .notDetermined: return "Pending"
    }
  }

  private func statusColor(_ status: PermissionStatus) -> Color {
    switch status {
    case .granted: return .green
    case .denied: return .red
    case .restricted: return .orange
    case .notDetermined: return .yellow
    }
  }

  private func saveAPIKey() {
    apiKeyValidationState = .validating
    let value = newAPIKeyValue.trimmingCharacters(in: .whitespacesAndNewlines)

    Task {
      let validation = await environment.openRouter.validateAPIKey(value)

      switch validation.outcome {
      case .success:
        do {
          try await environment.secureStorage.storeSecret(
            value,
            identifier: openRouterKeyIdentifier,
            label: "OpenRouter API Key"
          )

          let result = validation.updatingOutcome(
            .success(message: "Key saved and validated")
          )

          await MainActor.run {
            apiKeyValidationState = .finished(result)
            newAPIKeyValue = ""
          }
        } catch {
          let failure = APIKeyValidationResult.failure(
            message: "Failed to store key: \(error.localizedDescription)",
            debug: validation.debug
          )
          await MainActor.run {
            apiKeyValidationState = .finished(failure)
          }
        }
      case .failure:
        await MainActor.run {
          apiKeyValidationState = .finished(validation)
        }
      }
    }
  }

  private func settingsBinding<Value: Hashable>(
    _ keyPath: ReferenceWritableKeyPath<AppSettings, Value>
  ) -> Binding<Value> {
    Binding(
      get: { settings[keyPath: keyPath] },
      set: { settings[keyPath: keyPath] = $0 }
    )
  }

  private func settingsToggle(_ label: String, isOn: Binding<Bool>, tint: Color) -> some View {
    Toggle(label, isOn: isOn)
      .tint(tint)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
  }

  private func speedModeIcon(for mode: AppSettings.SpeedMode) -> String {
    switch mode {
    case .instant:
      return "bolt.fill"
    case .livePolish:
      return "sparkles"
    case .liveStructured:
      return "list.bullet.rectangle"
    case .utteranceFinalize:
      return "pause.circle"
    }
  }

  @MainActor
  private func generateSystemPromptPreview() {
    var sections: [String] = []

    // Base prompt
    let trimmed = self.settings.postProcessingSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let basePrompt = trimmed.isEmpty ? PostProcessingManager.defaultPrompt : trimmed

    let rawLanguage = self.settings.postProcessingOutputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    let language: String
    if rawLanguage.uppercased() == "ENGB" || rawLanguage.lowercased() == "en_gb" {
      language = "British English"
    } else {
      language = rawLanguage
    }

    var finalBasePrompt = basePrompt
    if !language.isEmpty {
      finalBasePrompt = "Always output using \(language). \(basePrompt)"
    }

    // Lexicon directives section
    if self.settings.postProcessingIncludeLexiconDirectives {
      let lexiconCount = self.environment.personalLexicon.rules.count
      let lexiconSection = """
      Personal lexicon directives (internal use only):
      - [Example: \(lexiconCount) active correction rules will be inserted here]
      Apply these silently and never repeat or reference them in the response.
      """
      sections.append(lexiconSection)
    }

    // Context tags section (shown in base prompt)
    if self.settings.postProcessingIncludeContextTags {
      sections.append(finalBasePrompt + "\nContext tags: [Tags will be inserted based on active app context].")
    } else {
      sections.append(finalBasePrompt)
    }

    // Final instruction
    if self.settings.postProcessingIncludeFinalInstruction {
      sections.append("Return only the processed text and nothing else. The following message is a raw transcript:")
    }

    self.systemPromptPreview = sections.joined(separator: "\n\n")
  }
}

private struct LocaleOption: Identifiable, Equatable {
  let displayName: String
  let identifier: String
  var id: String { identifier }
}

private struct SettingsCard<Content: View>: View {
  let title: String
  let systemImage: String
  let tint: Color
  @ViewBuilder let content: Content

  init(title: String, systemImage: String, tint: Color, @ViewBuilder content: () -> Content) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 14) {
        ZStack {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(tint.opacity(0.15))
            .frame(width: 44, height: 44)
          Image(systemName: systemImage)
            .foregroundStyle(tint)
            .font(.system(size: 20, weight: .semibold))
        }

        Text(title)
          .font(.headline)
          .foregroundStyle(.primary)
        Spacer()
      }

      content
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 26, style: .continuous)
        .stroke(tint.opacity(0.12), lineWidth: 1)
        .allowsHitTesting(false)
    )
    .shadow(color: tint.opacity(0.08), radius: 18, x: 0, y: 12)
  }
}

private struct ModelPicker: View {
  let title: String
  let help: String?
  let options: [ModelCatalog.Option]
  @Binding var value: String

  private struct ModelTagBadges: View {
    let tags: [ModelCatalog.Tag]
    let compact: Bool

    var body: some View {
      if tags.isEmpty {
        EmptyView()
      } else {
        HStack(spacing: 6) {
          ForEach(tags.prefix(compact ? 2 : tags.count), id: \.self) { tag in
            Text(tag.displayName)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(tagForegroundColor(tag))
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(
                Capsule(style: .continuous)
                  .fill(tagBackgroundColor(tag))
              )
          }
        }
      }
    }

    private func tagBackgroundColor(_ tag: ModelCatalog.Tag) -> Color {
      switch tag {
      case .fast: return Color.blue.opacity(0.12)
      case .cheap: return Color.green.opacity(0.14)
      case .quality: return Color.purple.opacity(0.12)
      case .leading: return Color.orange.opacity(0.14)
      }
    }

    private func tagForegroundColor(_ tag: ModelCatalog.Tag) -> Color {
      switch tag {
      case .fast: return .blue
      case .cheap: return .green
      case .quality: return .purple
      case .leading: return .orange
      }
    }
  }

  @State private var selection: String
  @State private var customValue: String

  init(title: String, help: String? = nil, options: [ModelCatalog.Option], value: Binding<String>) {
    self.title = title
    self.help = help
    self.options = options
    _value = value

    let trimmed = value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if let match = options.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
      _selection = State(initialValue: match.id)
      _customValue = State(initialValue: "")
    } else if trimmed.isEmpty, let first = options.first {
      _selection = State(initialValue: first.id)
      _customValue = State(initialValue: "")
      DispatchQueue.main.async {
        value.wrappedValue = first.id
      }
    } else {
      _selection = State(initialValue: ModelCatalog.customOptionID)
      _customValue = State(initialValue: trimmed)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker(title, selection: $selection) {
        ForEach(options) { option in
          HStack {
            Text(option.displayName)
            Spacer()
            ModelTagBadges(tags: option.tags, compact: true)
            LatencyBadgeCompact(option: option)
          }
          .tag(option.id)
        }
        Text("Custom…").tag(ModelCatalog.customOptionID)
      }
      .pickerStyle(.menu)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
      .speakTooltip(tooltipText)

      if let help {
        Text(help)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let option = selectedOption {
        HStack(spacing: 8) {
          if let description = option.description {
            Text(description)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          ModelTagBadges(tags: option.tags, compact: false)
          LatencyBadge(option: option)
        }
      }

      if selection == ModelCatalog.customOptionID {
        TextField("Custom model identifier", text: $customValue, prompt: Text("provider/model"))
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()
          .speakTooltip("Type the exact provider/model identifier from your transcription service, such as openai/whisper-1.")
      } else {
        HStack(spacing: 6) {
          Image(systemName: "info.circle")
            .imageScale(.small)
            .foregroundStyle(.secondary)
          Text(ModelCatalog.friendlyName(for: value))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .onChange(of: selection) { _, newValue in
      if newValue == ModelCatalog.customOptionID {
        if customValue.isEmpty {
          customValue = value
        }
        value = customValue.trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        value = newValue
      }
    }
    .onChange(of: customValue) { _, newValue in
      if selection == ModelCatalog.customOptionID {
        value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
  }

  private var selectedOption: ModelCatalog.Option? {
    options.first { option in
      option.id.caseInsensitiveCompare(selection) == .orderedSame
    }
  }

  private var tooltipText: String {
    if let help, !help.isEmpty {
      return help
    }
    if let description = selectedOption?.description, !description.isEmpty {
      return description
    }
    return "Choose which model Speak should use for this step."
  }
}

private struct APIKeyValidationDebugDetailsView: View {
  let debug: APIKeyValidationDebugSnapshot
  @State private var isExpanded: Bool = true

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 16) {
        debugSection(title: "Request") {
          debugRow(label: "URL", value: debug.url)
          debugRow(label: "Method", value: debug.method)
          if !debug.requestHeaders.isEmpty {
            headersSection(title: "Headers", headers: debug.requestHeaders)
          }
          if let body = debug.requestBody, !body.isEmpty {
            bodySection(title: "Body", value: body)
          }
        }

        debugSection(title: "Response") {
          if let status = debug.statusCode {
            debugRow(label: "Status", value: String(status))
          }
          if !debug.responseHeaders.isEmpty {
            headersSection(title: "Headers", headers: debug.responseHeaders)
          }
          if let body = debug.responseBody, !body.isEmpty {
            bodySection(title: "Body", value: body)
          }
        }

        if let error = debug.errorDescription, !error.isEmpty {
          debugSection(title: "Error") {
            Text(error)
              .font(.caption.monospaced())
              .foregroundStyle(.red)
          }
        }
      }
      .padding(.top, 6)
    } label: {
      Label("Latest validation details", systemImage: "ladybug")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func debugSection<Content: View>(title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      content()
    }
  }

  private func debugRow(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label + ":")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption.monospaced())
        .foregroundStyle(.primary)
      Spacer()
    }
  }

  @ViewBuilder
  private func headersSection(title: String, headers: [String: String]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
          Text("\(entry.key): \(entry.value)")
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      .padding(8)
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
  }

  @ViewBuilder
  private func bodySection(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          pasteboard.setString(value, forType: .string)
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .speakTooltip("Copy to clipboard")
      }
      ScrollView(.vertical) {
        Text(value)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 160)
      .padding(8)
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
  }
}

// MARK: - Pronunciation Entry Helper

private struct PronunciationEntryView: View {
  @Binding var dictionary: [String: String]
  @State private var newWord = ""
  @State private var newPronunciation = ""

  var body: some View {
    HStack(spacing: 8) {
      TextField("Word", text: $newWord)
        .textFieldStyle(.roundedBorder)
        .frame(width: 120)

      Text("→")
        .foregroundStyle(.secondary)

      TextField("Pronunciation", text: $newPronunciation)
        .textFieldStyle(.roundedBorder)
        .frame(width: 150)

      Button("Add") {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let pronunciation = newPronunciation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !pronunciation.isEmpty else { return }
        dictionary[word] = pronunciation
        newWord = ""
        newPronunciation = ""
      }
      .buttonStyle(.bordered)
      .disabled(newWord.isEmpty || newPronunciation.isEmpty)
    }

    Text("Example: \"GIF\" → \"jif\" or \"API\" → \"A P I\"")
      .font(.caption2)
      .foregroundStyle(.tertiary)
  }
}

// @Implement: This view allows management of all settings within the app settings class. Each logical grouping of settings should have it's own segment in a tab bar at the top of the view. All settings should be immediately persisted through the AppSettings class when they are changed. Break down the view in to smaller components for easier management.
// - API key management: This should save to key vault. When a key is added it should validate using an api call. Each key should have red/green indicators to confirm it's saved or not.
// - General configuration (including light/dark mode), delete any caches or audio files. Text Output configuration. Show status bar only/run in background mode but still can open the app from the status bar.
// - Transcription configuration - if it's using a live transcribe with osx native (or select an api to stream to) or if it's batch and will send the file after. And which model to use for each of those and any model configuration
// - Post-processing configuration. System prompt and temperature, model selection, enabled or disabled.
// - Hotkey management and configuration: This should allow selection of a hotkey (default should be the fn key). Probably a https://github.com/sindresorhus/KeyboardShortcuts is a good choice
// - Permission management: Call from permissions manager to see and ask for permissions and allow the user to validate easily for each one if it was correctly granted. Perhaps a test button that tries to use the permission and validates the outcome somehow.
// And then any other sections you think are relevant. This should be presented in a concise but user-friendly format.
