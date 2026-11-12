import SpeakCore
import SpeakHotKeys
import SpeakSync
import AppKit
import SwiftUI

extension SettingsView {
  var transcriptionSettings: some View {
    SpeakDensitySettingsSection(density: settings.visualDensity) {
      // 1. Where transcription runs.
      transcriptionModeCard

      if settings.transcriptionMode == .batchRemote && hidesModelSelection {
        simpleModelChoicesNotice
      }

      // 2. Which model runs it. Exactly one of these matches the selected mode.
      // Live transcription still uses the user's selected provider and key.
      if isRemoteStreamingTranscriptionSelected {
        remoteStreamingModelCard
      }
      if settings.transcriptionMode == .batchRemote && !hidesModelSelection {
        remoteBatchModelCard
      }
      if isAppleOnDeviceTranscriptionSelected {
        appleOnDeviceModelCard
      }
      if settings.transcriptionMode == .localModel {
        LocalTranscriptionModelsCard(starterPresetActivationTask: $starterPresetActivationTask)
      }

      if !settings.recoveredTranscriptionKeywords.isEmpty {
        transcriptionKeywordRecoveryCard
      }

      // 3. Options that depend on the chosen model.
      if isRemoteStreamingTranscriptionSelected {
        processingSpeedCard
      }
      if settings.hasSelectedModulateModel {
        modulateFeatureSettings
      }
      if settings.hasSelectedMetaMuseModel {
        metaMuseRecognitionBiasCard
      }

      // 4–5. How a recording starts and stops, and its fine-tuning delays.
      RecordingStartStopSettingsCards()
    }
  }

  /// Local vs. remote, and batch vs. streaming.
  private var transcriptionModeCard: some View {
    SettingsCard(title: "Transcription mode", systemImage: "waveform", tint: Color.teal) {
      VStack(alignment: .leading, spacing: 12) {
        Picker("Where transcription runs", selection: transcriptionLocationBinding) {
          ForEach(TranscriptionLocation.allCases) { location in
            Text(location.displayName).tag(location)
          }
        }
        .settingsSegmentedPicker()
        .speakTooltip("Choose whether Speak transcribes locally on this Mac or remotely with a provider.")
        .accessibilityLabel("Transcription location picker")

        if isLocalTranscriptionSelected {
          Picker("Local transcription source", selection: localTranscriptionSourceBinding) {
            ForEach(LocalTranscriptionSource.allCases) { source in
              Text(source.displayName).tag(source)
            }
          }
          .modifier(TranscriptionModeSegmentedPickerStyle())
          .speakTooltip("Choose built-in Apple Speech or a downloaded Core ML model.")
          .accessibilityLabel("Local transcription source picker")

          if settings.transcriptionMode == .localModel {
            if DistributionChannel.current.supportsInProcessLocalStreaming {
              Picker(
                "Downloaded transcription type",
                selection: settingsBinding(\AppSettings.localTranscriptionMode)
              ) {
                ForEach(orderedLocalTranscriptionModes) { mode in
                  Text(transcriptionModeSegmentLabel(from: mode.displayName)).tag(mode)
                }
              }
              .modifier(TranscriptionModeSegmentedPickerStyle())
              .speakTooltip(
                "Choose Batch for WhisperKit/Core ML, or Streaming for FluidAudio/Core ML and optional sherpa-onnx."
              )
              .accessibilityLabel("Downloaded transcription type picker")
            } else {
              Text("Downloaded WhisperKit/Core ML models run in-process as Local Batch transcription.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        } else {
          Picker("Remote transcription type", selection: remoteTranscriptionModeBinding) {
            ForEach(orderedRemoteTranscriptionModes) { mode in
              Text(transcriptionModeSegmentLabel(from: mode.displayName)).tag(mode)
            }
          }
          .modifier(TranscriptionModeSegmentedPickerStyle())
          .speakTooltip(
            "Choose Remote Streaming for live provider updates, or Remote Batch for post-recording transcription."
          )
          .accessibilityLabel("Remote transcription type picker")
        }

      }
    }
    .speakTooltip("Choose whether Speak transcribes on this Mac or with a remote provider, and how.")
  }

  /// Language and vocabulary bias sent with Meta Muse Voice Transcribe requests.
  /// Reuses the shared keyterms setting, as the OpenAI Realtime path does.
  private var metaMuseRecognitionBiasCard: some View {
    SettingsCard(
      title: "Meta Muse recognition bias",
      systemImage: "textformat.abc",
      tint: Color.blue
    ) {
      VStack(alignment: .leading, spacing: 8) {
        Text(
          "The preferred language setting supplies Meta's language bias. "
            + "Add comma-separated names, acronyms, places, or domain terms for vocabulary biasing."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        TextField(
          "JustSpeakToIt, Meta Model API, Muse Voice",
          text: settingsBinding(\AppSettings.assemblyAIKeyterms)
        )
        .textFieldStyle(.roundedBorder)
      }
    }
    .speakTooltip("Add vocabulary hints for Meta Muse Voice Transcribe.")
  }

  /// Provider model used while recording.
  private var remoteStreamingModelCard: some View {
    SettingsCard(title: "Remote Streaming model", systemImage: "mic.fill", tint: Color.brandAccentDeep) {
      VStack(alignment: .leading, spacing: 12) {
        SettingsModeBadge(
          title: "Fastest - Real-time Response",
          systemImage: "bolt.fill",
          tint: Color.brandAccentDeep
        )

        Text("Model used while recording. Provides instant feedback as you speak.")
          .font(.caption)
          .foregroundStyle(.secondary)
        ModelPicker(
          title: "Remote Streaming Model",
          help: "Choose the remote provider model used while recording.",
          options: ModelCatalog.remoteLiveTranscription,
          value: remoteTranscriptionModelBinding(
            \AppSettings.liveTranscriptionModel,
            options: ModelCatalog.remoteLiveTranscription
          ),
          credentialPurpose: .liveTranscription,
          storedAPIKeyIdentifiers: Set(settings.trackedAPIKeyIdentifiers)
        )
      }
    }
    .speakTooltip("Pick the remote model that transcribes as you speak during streaming recording.")
  }

  /// Provider model used after recording stops.
  private var remoteBatchModelCard: some View {
    SettingsCard(
      title: "Remote Batch model", systemImage: "folder.badge.clock", tint: Color.brandLagoon
    ) {
      VStack(alignment: .leading, spacing: 12) {
        SettingsModeBadge(
          title: "Best Quality - Most Accurate",
          systemImage: "star.fill",
          tint: Color.brandLagoon
        )

        Text("Model used when the recording is uploaded after it finishes. Delivers the highest accuracy.")
          .font(.caption)
          .foregroundStyle(.secondary)
        ModelPicker(
          title: "Remote Batch Model",
          help: """
          Remote transcription runs after recording stops. Built-in providers use their own keys; \
          custom model identifiers are sent through OpenRouter.
          """,
          options: batchTranscriptionOptions,
          value: remoteTranscriptionModelBinding(
            \AppSettings.batchTranscriptionModel,
            options: ModelCatalog.batchTranscription
          ),
          credentialPurpose: .batchTranscription,
          storedAPIKeyIdentifiers: Set(settings.trackedAPIKeyIdentifiers),
          openRouterBrowser: { select, back in
            AnyView(
              OpenRouterTranscriptionBrowser(
                apiKeyProvider: { [storage = environment.secureStorage] in
                  try? await storage.secret(identifier: "openrouter.apiKey")
                },
                selection: settings.batchTranscriptionModel,
                bundled: ModelCatalog.batchTranscription,
                onBack: back,
                onSelect: select
              )
            )
          }
        )
        if isCustomBatchTranscriptionModel {
          SettingsInlineInfo(
            title: "Custom batch models use OpenRouter",
            message:
              """
              Speak will send this custom model identifier to OpenRouter. Save an OpenRouter API key \
              before recording, or choose one of the built-in provider models above.
              """,
            systemImage: "key.fill"
          )
          if !isOpenRouterKeyStored {
            HStack(spacing: 10) {
              Label("OpenRouter API key missing", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
              Button("Add OpenRouter Key") {
                sidebarSelection = .settings(.apiKeys)
              }
              .buttonStyle(.bordered)
            }
          }
        }
      }
    }
    .speakTooltip("Tell Speak which cloud transcription model should polish the full recording.")
  }

  /// Apple's built-in speech engine.
  private var appleOnDeviceModelCard: some View {
    SettingsCard(
      title: "Apple on-device transcription",
      systemImage: "apple.logo",
      tint: Color.green
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Uses Apple's built-in speech engine. Audio stays on this device.")
          .font(.caption)
          .foregroundStyle(.secondary)
        ModelPicker(
          title: "Apple Model",
          help: "Choose the Apple on-device engine used while recording.",
          options: ModelCatalog.onDeviceLiveTranscription,
          value: remoteTranscriptionModelBinding(
            \AppSettings.liveTranscriptionModel,
            options: ModelCatalog.onDeviceLiveTranscription
          ),
          credentialPurpose: .liveTranscription,
          storedAPIKeyIdentifiers: Set(settings.trackedAPIKeyIdentifiers),
          allowsCustom: false
        )
      }
    }
    .speakTooltip("Choose an on-device Apple transcription engine.")
  }

  /// Auto-clean speed modes offered by Remote Streaming providers.
  private var processingSpeedCard: some View {
    SettingsCard(
      title: "Processing Speed",
      systemImage: "gauge.with.dots.needle.67percent",
      tint: Color.brandLagoon
    ) {
      let capabilities = settings.liveModelCapabilities
      let anyEnhancedModeAvailable = AppSettings.SpeedMode.allCases
        .contains { $0 != .instant && capabilities.supportedSpeedModes.contains($0.coreID) }

      VStack(alignment: .leading, spacing: 12) {
        Text("Auto-clean modes require a Remote Streaming transcription model and disable post-processing.")
          .font(.callout)
          .foregroundStyle(.secondary)

        if !anyEnhancedModeAvailable {
          Text("To enable these modes, select a Remote Streaming model such as Deepgram Nova-3 Streaming.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if settings.isAssemblyAIModel && capabilities.postStopFinalizeBudget > 0 {
          let budgetSeconds = String(format: "%.1f", capabilities.postStopFinalizeBudget)
          Text("Note: AssemblyAI may take up to ~\(budgetSeconds)s to finalise after you stop, "
               + "because it formats the full turn server-side.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        VStack(spacing: 8) {
          ForEach(AppSettings.SpeedMode.allCases) { mode in
            let isSupported = settings.supports(speedMode: mode)
            Button {
              settings.speedMode = mode
            } label: {
              HStack(spacing: 12) {
                Image(systemName: speedModeIcon(for: mode))
                  .font(.title3)
                  .foregroundStyle(settings.speedMode == mode ? .white : .brandLagoon)
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
                  .fill(settings.speedMode == mode ? Color.brandLagoon : Color(nsColor: .controlBackgroundColor))
              )
            }
            .buttonStyle(.plain)
            .disabled(!isSupported)
            .opacity(isSupported ? 1.0 : 0.6)
          }
        }
      }
    }
    .speakTooltip("Control the trade-off between speed and AI-powered text cleanup.")
  }

  var transcriptionLocationBinding: Binding<TranscriptionLocation> {
    Binding(
      get: { settings.transcriptionLocation },
      set: { settings.selectTranscriptionLocation($0) }
    )
  }

  var localTranscriptionSourceBinding: Binding<LocalTranscriptionSource> {
    Binding(
      get: { settings.localTranscriptionSource },
      set: { settings.selectLocalTranscriptionSource($0) }
    )
  }

  var remoteTranscriptionModeBinding: Binding<RemoteTranscriptionMode> {
    Binding(
      get: { settings.remoteTranscriptionMode },
      set: { settings.selectRemoteTranscriptionMode($0) }
    )
  }

  func transcriptionModeSegmentLabel(from displayName: String) -> String {
    displayName
      .replacingOccurrences(of: "Local ", with: "")
      .replacingOccurrences(of: "Remote ", with: "")
  }

  var isStreamingTranscriptionSelected: Bool { settings.isStreamingTranscriptionSelected }

  var isAppleOnDeviceTranscriptionSelected: Bool { settings.isAppleOnDeviceTranscriptionSelected }

  var isLocalTranscriptionSelected: Bool { settings.isLocalTranscriptionSelected }

  var isRemoteStreamingTranscriptionSelected: Bool { settings.isRemoteStreamingTranscriptionSelected }

  func speedModeIcon(for mode: AppSettings.SpeedMode) -> String {
    switch mode {
    case .instant:
      return "bolt.fill"
    case .livePolish:
      return "sparkles"
    }
  }

  var localPostProcessingOptions: [ModelCatalog.Option] {
    localPostProcessingModels.settingsPickerOptions
  }

  var cloudPostProcessingOptions: [ModelCatalog.Option] {
    CleanupModelDiscoveryStore.shared.options(selected: settings.postProcessingModel)
  }

  /// The batch catalogue plus a saved live-discovered OpenRouter choice, so the
  /// picker names it rather than showing it as a custom identifier.
  private var batchTranscriptionOptions: [ModelCatalog.Option] {
    let selected = settings.batchTranscriptionModel
    guard let modelID = OpenRouterTranscriptionSelection.modelID(from: selected) else {
      return ModelCatalog.batchTranscription
    }
    return ModelCatalog.batchTranscription + [
      .init(id: selected, displayName: modelID, description: "Discovered OpenRouter speech-to-text model.")
    ]
  }

  private var isCustomBatchTranscriptionModel: Bool {
    let model = settings.batchTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { return false }
    return !ModelCatalog.batchTranscription.contains {
      $0.id.caseInsensitiveCompare(model) == .orderedSame
    }
  }
}
