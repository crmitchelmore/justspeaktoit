// swiftlint:disable file_length
import SpeakCore
import SpeakHotKeys
import SpeakSync
import AppKit
import SwiftUI

extension SettingsView {
  var transcriptionSettings: some View {
    SpeakDensitySettingsSection(density: settings.visualDensity) {
      SettingsCard(title: "Transcription mode", systemImage: "waveform", tint: Color.teal) {
        VStack(alignment: .leading, spacing: 12) {
          Picker("Where transcription runs", selection: transcriptionLocationBinding) {
            ForEach(TranscriptionLocation.allCases) { location in
              Text(location.displayName).tag(location)
            }
          }
          .pickerStyle(.segmented)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
          )
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
      .speakTooltip("Choose which transcription flow Speak uses and the locale it should prefer.")

      if isRemoteStreamingTranscriptionSelected {
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

      if !isStreamingTranscriptionSelected {
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

      if isStreamingTranscriptionSelected {
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

      if !isStreamingTranscriptionSelected {
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
      }

      if hidesModelSelection {
        simpleModelChoicesNotice
      }

      if isRemoteStreamingTranscriptionSelected, !hidesModelSelection {
        SettingsCard(title: "Remote Streaming model", systemImage: "mic.fill", tint: Color.brandAccentDeep) {
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
              Image(systemName: "bolt.fill")
                .foregroundStyle(Color.brandAccentDeep)
                .imageScale(.small)
              Text("Fastest - Real-time Response")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.brandAccentDeep)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
              Capsule()
                .fill(Color.brandAccentDeep.opacity(0.12))
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

      if settings.transcriptionMode == .batchRemote, !hidesModelSelection {
        SettingsCard(
          title: "Remote Batch model", systemImage: "folder.badge.clock", tint: Color.brandLagoon
        ) {
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
              Image(systemName: "star.fill")
                .foregroundStyle(Color.brandLagoon)
                .imageScale(.small)
              Text("Best Quality - Most Accurate")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.brandLagoon)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
              Capsule()
                .fill(Color.brandLagoon.opacity(0.12))
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
              options: ModelCatalog.batchTranscription,
              value: remoteTranscriptionModelBinding(
                \AppSettings.batchTranscriptionModel,
                options: ModelCatalog.batchTranscription
              ),
              credentialPurpose: .batchTranscription,
              storedAPIKeyIdentifiers: Set(settings.trackedAPIKeyIdentifiers)
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

      if isAppleOnDeviceTranscriptionSelected, !hidesModelSelection {
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

      if settings.transcriptionMode == .localModel, !hidesModelSelection {
        SettingsCard(
          title: "Local transcription models",
          systemImage: "externaldrive.badge.checkmark",
          tint: Color.green
        ) {
          VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
              Image(systemName: "lock.shield.fill")
                .foregroundStyle(Color.green)
                .imageScale(.small)
              Text(
                settings.localTranscriptionMode == .batch
                  ? "Local Batch - private on this Mac"
                  : "Local Streaming - private on this Mac"
              )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.green)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
              Capsule()
                .fill(Color.green.opacity(0.12))
            )

            Text(
              "Choose a ready-made setup below. Speak will select the right local mode "
                + "and download everything it needs."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            localModelStarterSetup

            DisclosureGroup(isExpanded: $isLocalTranscriptionAdvancedExpanded) {
              VStack(alignment: .leading, spacing: 16) {
                Text(
                  {
                    #if APP_STORE
                    return """
                    Downloaded transcription is separate from Apple Speech and cloud providers. \
                    WhisperKit/Core ML model data runs in-process and is supported in this App Store build.
                    """
                    #else
                    return """
                    Downloaded transcription is separate from Apple Speech and cloud providers. \
                    Local Batch uses in-process WhisperKit/Core ML model data. Local Streaming can use \
                    in-process FluidAudio/Core ML or an optional external sherpa-onnx runtime.
                    """
                    #endif
                  }()
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if !DistributionChannel.current.supportsExternalLocalModelRuntime {
                  localRuntimeUnavailableNote
                }

                localModelQuickStart
                if settings.localTranscriptionMode == .batch {
                  selectedLocalModelCallout
                  huggingFaceModelImport
                } else {
                  localStreamingStatus
                }

                if settings.localTranscriptionMode == .batch {
                  if localTranscriptionOptions.isEmpty {
                    Label(
                      "Download a local batch model before selecting it for recording.",
                      systemImage: "arrow.down.circle"
                    )
                      .font(.caption)
                      .foregroundStyle(.orange)
                  } else {
                    ModelPicker(
                      title: "Local Batch Model",
                      help: "Used for local-only transcription after recording stops.",
                      options: localTranscriptionOptions,
                      value: localTranscriptionModelBinding,
                      credentialPurpose: .batchTranscription,
                      storedAPIKeyIdentifiers: Set(settings.trackedAPIKeyIdentifiers),
                      allowsCustom: false
                    )
                  }

                  VStack(spacing: 10) {
                    ForEach(localTranscriptionModels) { model in
                      localModelRow(model)
                    }
                  }
                }
              }
              .padding(.top, 12)
            } label: {
              Label("Advanced model configuration", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
            }
            .padding(12)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
            )
            .speakTooltip(
              "Show every downloaded model, custom Hugging Face sources, runtime controls, and manual selection."
            )
          }
        }
        .speakTooltip("Download and manage private local transcription models.")
      }

      if settings.hasSelectedModulateModel {
        modulateFeatureSettings
      }
    }
  }

  private var localModelStarterSetup: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "wand.and.stars")
          .foregroundStyle(Color.green)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 3) {
          Text(settings.localTranscriptionMode == .streaming ? "Quick streaming setup" : "Quick batch setup")
            .font(.subheadline.weight(.semibold))
          Text(
            settings.localTranscriptionMode == .streaming
              ? "Choose fast English streaming or high-quality multilingual streaming."
              : "Use the recommended high-quality model after each recording finishes."
          )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      VStack(spacing: 10) {
        ForEach(localStarterPresets) { preset in
          localStarterPresetRow(preset)
        }
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.green.opacity(0.08))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.green.opacity(0.2), lineWidth: 1)
    )
  }

  private func localStarterPresetRow(_ preset: LocalTranscriptionStarterPreset) -> some View {
    let state = starterPresetInstallState(for: preset)
    let isSelected = isStarterPresetSelected(preset)
    return localModelRowContainer(isSelected: isSelected, tint: .green) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: starterPresetIcon(for: preset))
          .foregroundStyle(Color.green)
          .frame(width: 24)

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(preset.displayName)
              .font(.subheadline.weight(.semibold))
            localModelBadge(preset.recommendation, tint: .green)
            if isSelected {
              localModelBadge("Selected", tint: .blue)
            }
          }
          Text(preset.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("\(preset.runtime) · ~\(preset.approximateSizeMB) MB")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
          Text(starterPresetStatusText(for: state, isSelected: isSelected))
            .font(.caption2)
            .foregroundStyle(starterPresetStatusTint(for: state))
        }

        Spacer()

        VStack(alignment: .trailing, spacing: 8) {
          if state == .installing {
            starterPresetProgress(for: preset)
          } else {
            Button(starterPresetActionTitle(for: state, isSelected: isSelected)) {
              configureAndDownload(preset)
            }
            .buttonStyle(.borderedProminent)
            .disabled(state == .installed && isSelected)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func starterPresetProgress(for preset: LocalTranscriptionStarterPreset) -> some View {
    switch preset.engine {
    case .parakeet:
      ProgressView(value: fluidAudioModels.downloadProgress)
        .frame(width: 90)
      Text("\(Int(fluidAudioModels.downloadProgress * 100))%")
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    case .whisperKit:
      ProgressView()
        .controlSize(.small)
      Text("Configuring")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private var localStarterPresets: [LocalTranscriptionStarterPreset] {
    LocalTranscriptionStarterPreset.recommended(
      for: settings.localTranscriptionMode,
      availableModels: localTranscriptionModels,
      supportsParakeet: FluidAudioModelManager.supportsCurrentHardware
    )
  }

  private func starterPresetInstallState(
    for preset: LocalTranscriptionStarterPreset
  ) -> StarterPresetInstallState {
    switch preset.engine {
    case .parakeet:
      switch fluidAudioModels.installState {
      case .notInstalled: return .notInstalled
      case .installing: return .installing
      case .installed: return .installed
      case .failed(let message): return .failed(message)
      }
    case .whisperKit(let model):
      switch localModels.installState(for: model.id) {
      case .notInstalled: return .notInstalled
      case .installing: return .installing
      case .installed: return .installed
      case .failed(let message): return .failed(message)
      }
    }
  }

  private func isStarterPresetSelected(_ preset: LocalTranscriptionStarterPreset) -> Bool {
    guard settings.transcriptionMode == .localModel,
      settings.localTranscriptionMode == preset.mode
    else { return false }

    switch preset.engine {
    case .parakeet:
      return settings.localStreamingModelSource == FluidAudioParakeetModel.id
    case .whisperKit(let model):
      if preset.mode == .streaming {
        return settings.localStreamingModelSource == WhisperKitStreamingModel.id(for: model)
      }
      return settings.localTranscriptionModel == model.id
    }
  }

  private func configureAndDownload(_ preset: LocalTranscriptionStarterPreset) {
    settings.transcriptionMode = .localModel
    settings.localTranscriptionMode = preset.mode

    switch preset.engine {
    case .parakeet:
      settings.localStreamingModelSource = FluidAudioParakeetModel.id
      guard fluidAudioModels.installState != .installed else { return }
      Task { await fluidAudioModels.install() }
    case .whisperKit(let model):
      settings.localTranscriptionModel = model.id
      if preset.mode == .streaming {
        settings.localStreamingModelSource = WhisperKitStreamingModel.id(for: model)
      }
      guard !localModels.isInstalled(model.id) else { return }
      Task { await localModels.install(model) }
    }
  }

  private func starterPresetIcon(for preset: LocalTranscriptionStarterPreset) -> String {
    switch preset.engine {
    case .parakeet: return "waveform.badge.mic"
    case .whisperKit: return preset.mode == .streaming ? "waveform" : "doc.text.magnifyingglass"
    }
  }

  private func starterPresetActionTitle(
    for state: StarterPresetInstallState,
    isSelected: Bool
  ) -> String {
    switch state {
    case .installed: return isSelected ? "Configured" : "Use This Setup"
    case .installing: return "Configuring"
    case .notInstalled, .failed: return "Configure and Download"
    }
  }

  private func starterPresetStatusText(
    for state: StarterPresetInstallState,
    isSelected: Bool
  ) -> String {
    switch state {
    case .installed: return isSelected ? "Configured and ready" : "Downloaded and ready to select"
    case .installing: return "Downloading and preparing the model"
    case .notInstalled: return "Not downloaded"
    case .failed(let message): return "Download failed: \(message)"
    }
  }

  private func starterPresetStatusTint(for state: StarterPresetInstallState) -> Color {
    switch state {
    case .installed: return .green
    case .installing: return .orange
    case .notInstalled: return .secondary
    case .failed: return .red
    }
  }

  // swiftlint:disable:next function_body_length
  private func localModelRow(_ model: LocalTranscriptionModel) -> some View {
    let state = localModels.installState(for: model.id)
    let isSelected = state == .installed && model.id == settings.localTranscriptionModel
    return localModelRowContainer(isSelected: isSelected, tint: .green) {
      HStack(alignment: .top, spacing: 12) {
      Image(systemName: localModelIcon(for: state))
        .foregroundStyle(localModelTint(for: state))
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(model.displayName)
            .font(.subheadline.weight(.semibold))
          if isSelected {
            localModelBadge("Selected", tint: .green)
          }
          localModelBadge(
            model.supportsLiveStreaming ? "Streaming" : "Offline",
            tint: model.supportsLiveStreaming ? Color.brandAccentDeep : Color.secondary
          )
        }
        Text(model.description)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(localModelSizeLabel(for: model))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
        if case .failed(let message) = state {
          Text(message)
            .font(.caption2)
            .foregroundStyle(.red)
        }
      }

      Spacer()

      switch state {
      case .installed:
        VStack(alignment: .trailing, spacing: 8) {
          if isSelected {
            selectedModelBadge()
          } else {
            Button("Use") {
              settings.localTranscriptionModel = model.id
            }
          }
          Button("Delete") {
            localModels.delete(model)
            if settings.localTranscriptionModel == model.id {
              if let fallback = firstInstalledLocalTranscriptionModelID(excluding: model.id) {
                settings.localTranscriptionModel = fallback
              } else {
                settings.transcriptionMode = .liveNative
              }
            }
          }
        }
      case .installing:
        VStack(alignment: .trailing, spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text("Preparing")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      case .notInstalled, .failed:
        VStack(alignment: .trailing, spacing: 8) {
          Button("Download") {
            Task { await localModels.install(model) }
          }
        }
      }
      }
    }
  }

  private var localModelQuickStart: some View {
    VStack(alignment: .leading, spacing: 8) {
      localModelStep(
        number: "1",
        title: "Choose Local mode",
        detail: "This switches recordings away from cloud providers."
      )
      localModelStep(
        number: "2",
        title: settings.localTranscriptionMode == .batch
          ? "Download a local batch model"
          : "Download a local streaming model",
        detail: settings.localTranscriptionMode == .batch
          ? "WhisperKit/Core ML models run locally after recording stops."
          : "Choose Parakeet or an installed WhisperKit model; both run in-process with Core ML."
      )
      localModelStep(
        number: "3",
        title: "Record normally",
        detail: settings.localTranscriptionMode == .batch
          ? "Speak transcribes after recording stops, offline on this Mac."
          : "Speak streams partial text locally while you record."
      )
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.green.opacity(0.08))
    )
  }

  var localRuntimeUnavailableNote: some View {
    channelAvailabilityNote(
      "External executable runtimes are unavailable in this build. "
        + "Bundled Parakeet and WhisperKit/Core ML streaming remain available."
    )
  }

  func channelAvailabilityNote(_ text: String) -> some View {
    Label(
      text,
      systemImage: "info.circle"
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  func localModelStep(number: String, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text(number)
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .frame(width: 20, height: 20)
        .background(Circle().fill(Color.green))
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption.weight(.semibold))
        Text(detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var huggingFaceModelImport: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "globe")
          .foregroundStyle(Color.green)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 3) {
          Text("Find more models on Hugging Face")
            .font(.subheadline.weight(.semibold))
          Text(
            """
            Browse WhisperKit/Core ML model repos, then paste the Hugging Face repo ID and model variant here. \
            Compatible WhisperKit models can be used for either local batch or local streaming.
            """
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      Button {
        openHuggingFaceModelSearch()
      } label: {
        Label("Browse compatible Hugging Face models", systemImage: "magnifyingglass")
      }

      VStack(alignment: .leading, spacing: 8) {
        TextField("Repo ID, e.g. argmaxinc/whisperkit-coreml", text: $huggingFaceRepoID)
          .textFieldStyle(.roundedBorder)
        TextField("Model variant, e.g. tiny, base, small", text: $huggingFaceModelName)
          .textFieldStyle(.roundedBorder)
      }

      HStack {
        Button {
          installHuggingFaceModel()
        } label: {
          Label("Install from Hugging Face", systemImage: "arrow.down.circle")
        }
        .disabled(!canImportHuggingFaceModel)

        Spacer()
      }

      if let huggingFaceImportError {
        Text(huggingFaceImportError)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.green.opacity(0.25), lineWidth: 1)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
    )
  }

  private var localStreamingStatus: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "antenna.radiowaves.left.and.right")
          .foregroundStyle(Color.orange)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 3) {
          Text("Local Streaming model sources")
            .font(.subheadline.weight(.semibold))
          Text(
            """
            These are local-only streaming candidates, not cloud providers. \
            Parakeet and WhisperKit run in-process with bundled Core ML runtimes.
            """
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      Label(
        "Local Streaming runs entirely on this Mac and never sends audio to the cloud.",
        systemImage: "lock.shield"
      )
        .font(.caption)
        .foregroundStyle(.orange)

      fluidAudioStreamingRow

      whisperKitStreamingRows

      #if !APP_STORE
      localStreamingRuntimeControls

      localStreamingSetupSection(
        title: "3. Add an optional sherpa-onnx model",
        subtitle: "Pick one of the compatible external-runtime models we know how to download and run locally.",
        systemImage: "checklist",
        tint: .orange
      ) {
        Picker("Available local streaming candidates", selection: $selectedRecommendedStreamingSourceID) {
          ForEach(LocalModelManager.recommendedStreamingModelSources) { source in
            Text("\(source.modelName) (\(localStreamingSizeLabel(for: source)))").tag(source.id)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
        )
        if let source = selectedRecommendedStreamingSource {
          Text("\(source.runtime) · \(localStreamingSizeLabel(for: source)) · local-only streaming.")
            .font(.caption)
            .foregroundStyle(.secondary)
          if source.id == ParakeetLocalModels.tdtV3Int8SourceID {
            Text(ParakeetLocalModels.tdtV3SettingsSummary)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Button {
          addSelectedStreamingModelSource()
        } label: {
          Label("Add selected model to Local Streaming", systemImage: "plus.circle")
        }
      }

      localStreamingSetupSection(
        title: "4. Browse for more local streaming models",
        subtitle: """
        Open Hugging Face search for sherpa-onnx streaming ASR models. \
        Only compatible sources can be added here.
        """,
        systemImage: "magnifyingglass",
        tint: .blue
      ) {
        Button {
          openLocalStreamingModelSearch()
        } label: {
          Label("Browse Hugging Face streaming ASR models", systemImage: "arrow.up.right.square")
        }
      }

      localStreamingSetupSection(
        title: "5. Add a source manually",
        subtitle: """
        Use this when you already know the Hugging Face repo and model name. \
        The model still stays local-only.
        """,
        systemImage: "keyboard",
        tint: .purple
      ) {
        TextField(
          "Repo ID, e.g. csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26",
          text: $streamingHuggingFaceRepoID
        )
          .textFieldStyle(.roundedBorder)
        TextField("Model name, e.g. streaming-zipformer-en-2023-06-26", text: $streamingHuggingFaceModelName)
          .textFieldStyle(.roundedBorder)
        HStack {
          Button {
            addStreamingModelSource()
          } label: {
            Label("Add manual streaming source", systemImage: "plus.circle")
          }
          .disabled(!canAddStreamingModelSource)
          Spacer()
        }
      }

      if let streamingHuggingFaceImportError {
        Text(streamingHuggingFaceImportError)
          .font(.caption)
          .foregroundStyle(.red)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Downloaded / added local streaming models")
          .font(.caption.weight(.semibold))
        if localModels.streamingModelSources.isEmpty {
          Label(
            "No local streaming models have been added yet. Start with a recommended model above.",
            systemImage: "tray"
          )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          VStack(spacing: 10) {
            ForEach(localModels.streamingModelSources) { source in
              localStreamingSourceRow(source)
            }
          }
        }
      }
      #endif
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.orange.opacity(0.08))
    )
  }

  private var fluidAudioStreamingRow: some View {
    let state = fluidAudioModels.installState
    let isSelected = state == .installed
      && settings.localStreamingModelSource == FluidAudioParakeetModel.id
    return localStreamingSetupSection(
      title: "1. Recommended: Parakeet Realtime",
      subtitle: "The fastest path: an in-process Core ML model with no Python or external runtime.",
      systemImage: "bolt.fill",
      tint: .green
    ) {
      localModelRowContainer(isSelected: isSelected, tint: .green) {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "waveform.badge.mic")
            .foregroundStyle(Color.green)
            .frame(width: 24)

          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
              Text(FluidAudioParakeetModel.displayName)
                .font(.subheadline.weight(.semibold))
              if isSelected {
                localModelBadge("Selected", tint: .green)
              }
              localModelBadge("English", tint: .secondary)
            }
            Text(FluidAudioParakeetModel.description)
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(
              "\(FluidAudioParakeetModel.runtimeName) · ~\(FluidAudioParakeetModel.approximateSizeMB) MB"
            )
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.tertiary)
            Text(fluidAudioInstallLabel)
              .font(.caption2)
              .foregroundStyle(.secondary)
            if case .failed(let message) = state {
              Text(message)
                .font(.caption2)
                .foregroundStyle(.red)
            }
          }

          Spacer()

          VStack(alignment: .trailing, spacing: 8) {
            switch state {
            case .installed:
              if isSelected {
                selectedModelBadge(tint: .green)
              } else {
                Button("Use") {
                  settings.localStreamingModelSource = FluidAudioParakeetModel.id
                }
              }
              Button("Delete") {
                fluidAudioModels.delete()
                if settings.localStreamingModelSource == FluidAudioParakeetModel.id {
                  if let fallback = firstInstalledStreamingSourceID(excluding: FluidAudioParakeetModel.id) {
                    settings.localStreamingModelSource = fallback
                  } else {
                    settings.localStreamingModelSource = ""
                    settings.localTranscriptionMode = .batch
                  }
                }
              }
            case .installing:
              ProgressView(value: fluidAudioModels.downloadProgress)
                .frame(width: 90)
              Text("\(Int(fluidAudioModels.downloadProgress * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            case .notInstalled, .failed:
              Button("Download") {
                Task { await fluidAudioModels.install() }
              }
              .disabled(!FluidAudioModelManager.supportsCurrentHardware)
            }
          }
        }
      }
    }
  }

  private var fluidAudioInstallLabel: String {
    switch fluidAudioModels.installState {
    case .installed:
      return "downloaded and ready"
    case .installing:
      return "downloading and compiling Core ML models"
    case .failed(let message):
      return "download failed: \(message)"
    case .notInstalled:
      return FluidAudioModelManager.supportsCurrentHardware
        ? "not downloaded"
        : "requires Apple silicon"
    }
  }

  private var whisperKitStreamingRows: some View {
    localStreamingSetupSection(
      title: "2. WhisperKit streaming",
      subtitle: "Use any downloaded WhisperKit/Core ML model for multilingual live transcription.",
      systemImage: "waveform",
      tint: .blue
    ) {
      VStack(spacing: 10) {
        ForEach(localStreamingModels) { model in
          whisperKitStreamingRow(model)
        }
      }
    }
  }

  // swiftlint:disable:next function_body_length
  private func whisperKitStreamingRow(_ model: LocalTranscriptionModel) -> some View {
    let state = localModels.installState(for: model.id)
    let streamingID = WhisperKitStreamingModel.id(for: model)
    let isSelected = state == .installed && settings.localStreamingModelSource == streamingID
    return localModelRowContainer(isSelected: isSelected, tint: .blue) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: localModelIcon(for: state))
          .foregroundStyle(localModelTint(for: state))
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(model.displayName)
              .font(.subheadline.weight(.semibold))
            if isSelected {
              localModelBadge("Selected", tint: .blue)
            }
            localModelBadge("Streaming", tint: .blue)
          }
          Text(model.description)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("WhisperKit / Core ML · \(localModelSizeLabel(for: model))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 8) {
          switch state {
          case .installed:
            if isSelected {
              selectedModelBadge(tint: .blue)
            } else {
              Button("Use") {
                settings.localStreamingModelSource = streamingID
              }
            }
            Button("Delete") {
              localModels.delete(model)
              if isSelected {
                if let fallback = firstInstalledStreamingSourceID(excluding: streamingID) {
                  settings.localStreamingModelSource = fallback
                } else {
                  settings.localStreamingModelSource = ""
                  settings.localTranscriptionMode = .batch
                }
              }
            }
          case .installing:
            ProgressView()
              .controlSize(.small)
          case .notInstalled, .failed:
            Button("Download") {
              Task { await localModels.install(model) }
            }
          }
        }
      }
    }
  }

  #if !APP_STORE
  // swiftlint:disable:next function_body_length
  private func localStreamingSourceRow(_ source: LocalStreamingModelSource) -> some View {
    let state = sherpaRuntime.modelStates[source.id] ?? .notInstalled
    let isSelected = state == .installed && settings.localStreamingModelSource == source.id
    return localModelRowContainer(isSelected: isSelected, tint: .orange) {
      HStack(alignment: .top, spacing: 12) {
      Image(systemName: "antenna.radiowaves.left.and.right")
        .foregroundStyle(Color.orange)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(source.displayName)
            .font(.subheadline.weight(.semibold))
          if isSelected {
            localModelBadge("Selected", tint: .orange)
          }
          localModelBadge("Local Streaming", tint: .orange)
        }
        Text(source.runtime)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("\(localStreamingSizeLabel(for: source)) - \(source.repoID) / \(source.modelName)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
        Text(localStreamingInstallLabel(for: source))
          .font(.caption2)
          .foregroundStyle(.secondary)
        if case .failed(let message) = state {
          Text(message)
            .font(.caption2)
            .foregroundStyle(.red)
        }
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 8) {
        switch state {
        case .installed:
          if isSelected {
            selectedModelBadge(tint: .orange)
          } else {
            Button("Use") {
              settings.localStreamingModelSource = source.id
            }
          }
        case .installing:
          VStack(alignment: .trailing, spacing: 6) {
            ProgressView()
              .controlSize(.small)
            Text("Downloading")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        case .notInstalled, .failed:
          Button("Download") {
            Task { await sherpaRuntime.installModel(source) }
          }
          .disabled(!sherpaRuntime.runtimeState.isInstalled)
          .speakTooltip(
            sherpaRuntime.runtimeState.isInstalled
              ? "Download this sherpa-onnx model for local-only streaming."
              : "Install the sherpa-onnx runtime first."
          )
        }
        Button("Remove") {
          localModels.deleteStreamingModelSource(source)
          if settings.localStreamingModelSource == source.id {
            if let fallback = firstInstalledStreamingSourceID(excluding: source.id) {
              settings.localStreamingModelSource = fallback
            } else {
              // Nothing installed is left, so point at a recommended source the
              // user could download next — never back at the source we removed.
              settings.localStreamingModelSource = LocalModelManager
                .recommendedStreamingModelSources
                .first { $0.id != source.id }?.id ?? ""
              settings.localTranscriptionMode = .batch
            }
          }
        }
      }
      }
    }
  }

  #endif

  private func localStreamingSetupSection<Content: View>(
    title: String,
    subtitle: String,
    systemImage: String,
    tint: Color,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: systemImage)
          .foregroundStyle(tint)
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.caption.weight(.semibold))
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      content()
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(tint.opacity(0.2), lineWidth: 1)
    )
  }

  #if !APP_STORE
  private var localStreamingRuntimeControls: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: sherpaRuntimeIcon)
        .foregroundStyle(sherpaRuntimeTint)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text("Optional sherpa-onnx local streaming runtime")
          .font(.caption.weight(.semibold))
        Text(sherpaRuntimeDetail)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer()
      switch sherpaRuntime.runtimeState {
      case .installed:
        Text("Installed")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.green)
      case .installing:
        ProgressView()
          .controlSize(.small)
      case .notInstalled, .failed:
        Button("Install Runtime") {
          Task { await sherpaRuntime.installRuntime() }
        }
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
    )
  }

  private var sherpaRuntimeIcon: String {
    switch sherpaRuntime.runtimeState {
    case .installed: return "checkmark.circle.fill"
    case .installing: return "arrow.down.circle"
    case .failed: return "exclamationmark.triangle.fill"
    case .notInstalled: return "shippingbox"
    }
  }

  private var sherpaRuntimeTint: Color {
    switch sherpaRuntime.runtimeState {
    case .installed: return .green
    case .installing: return .orange
    case .failed: return .red
    case .notInstalled: return .secondary
    }
  }

  private var sherpaRuntimeDetail: String {
    switch sherpaRuntime.runtimeState {
    case .installed:
      return "Ready for local streaming on this Mac."
    case .installing:
      return "Installing the pinned Python sherpa-onnx package."
    case .failed(let message):
      return message
    case .notInstalled:
      return "Experimental prerelease runtime. Requires Python 3 and installs sherpa-onnx locally."
    }
  }
  private func localStreamingInstallLabel(for source: LocalStreamingModelSource) -> String {
    switch sherpaRuntime.modelStates[source.id] ?? .notInstalled {
    case .installed:
      return "downloaded and ready"
    case .installing:
      return "downloading model files"
    case .failed(let message):
      return "download failed: \(message)"
    case .notInstalled:
      return "not downloaded"
    }
  }

  private func localStreamingSizeLabel(for source: LocalStreamingModelSource) -> String {
    guard let size = source.approximateSizeMB, size > 0 else {
      return "size shown after model metadata is known"
    }
    return "~\(size) MB"
  }
  #endif

  @ViewBuilder
  private var selectedLocalModelCallout: some View {
    if let model = selectedLocalModel, localModels.isInstalled(model.id) {
      let state = localModels.installState(for: model.id)
      HStack(alignment: .center, spacing: 12) {
        Image(systemName: selectedLocalModelStatusIcon(for: state))
          .foregroundStyle(localModelTint(for: state))
          .font(.title3)
          .frame(width: 24)

        VStack(alignment: .leading, spacing: 3) {
          Text(selectedLocalModelStatusTitle(for: state, model: model))
            .font(.subheadline.weight(.semibold))
          Text(selectedLocalModelStatusDetail(for: state, model: model))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        selectedLocalModelAction(for: state, model: model)
      }
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
    }
  }

  @ViewBuilder
  private func selectedLocalModelAction(
    for state: LocalModelManager.InstallState,
    model: LocalTranscriptionModel
  ) -> some View {
    switch state {
    case .installed:
      if settings.transcriptionMode == .localModel,
        settings.localTranscriptionMode == .streaming,
        !model.supportsLiveStreaming {
        Button("Use Offline") {
          settings.localTranscriptionMode = .batch
        }
      } else if settings.transcriptionMode == .localModel {
        VStack(alignment: .trailing, spacing: 6) {
          Label("Ready", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
          Button("Prepare Model") {
            Task { await localModels.install(model) }
          }
          .font(.caption)
        }
      } else {
        Button("Use Local Mode") {
          settings.transcriptionMode = .localModel
        }
      }
    case .installing:
      ProgressView()
        .controlSize(.small)
    case .notInstalled, .failed:
      Button("Download Selected") {
        Task { await localModels.install(model) }
      }
    }
  }

  private var selectedLocalModel: LocalTranscriptionModel? {
    localTranscriptionModels.first { $0.id == settings.localTranscriptionModel }
  }

  private var localTranscriptionModels: [LocalTranscriptionModel] {
    localModels.availableModels
  }

  var localTranscriptionOptions: [ModelCatalog.Option] {
    localModels.availableModels
      .filter { localModels.isInstalled($0.id) }
      .map(\.option)
  }

  var localPostProcessingOptions: [ModelCatalog.Option] {
    let builtIn = ModelCatalog.postProcessing.filter {
      PostProcessingManager.isLocalPostProcessingModel($0.id)
    }
    #if APP_STORE
    return builtIn
    #else
    let downloaded = localPostProcessingModels.availableModels
      .filter { localPostProcessingModels.isInstalled($0.id) }
      .map(\.option)
    return builtIn + downloaded
    #endif
  }

  var cloudPostProcessingOptions: [ModelCatalog.Option] {
    ModelCatalog.postProcessing.filter {
      !PostProcessingManager.isLocalPostProcessingModel($0.id)
    }
  }

  private var localStreamingModels: [LocalTranscriptionModel] {
    localTranscriptionModels.filter(\.supportsLiveStreaming)
  }

  private var canImportHuggingFaceModel: Bool {
    huggingFaceRepoID.split(separator: "/").count == 2
      && !huggingFaceModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  #if !APP_STORE
  private var canAddStreamingModelSource: Bool {
    streamingHuggingFaceRepoID.split(separator: "/").count == 2
      && !streamingHuggingFaceModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  #endif

  private var isCustomBatchTranscriptionModel: Bool {
    let model = settings.batchTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { return false }
    return !ModelCatalog.batchTranscription.contains {
      $0.id.caseInsensitiveCompare(model) == .orderedSame
    }
  }

  #if !APP_STORE
  private var selectedRecommendedStreamingSource: LocalStreamingModelSource? {
    LocalModelManager.recommendedStreamingModelSources.first {
      $0.id == selectedRecommendedStreamingSourceID
    } ?? LocalModelManager.recommendedStreamingModelSources.first
  }
  #endif

  private func openHuggingFaceModelSearch() {
    guard let url = URL(
      string: "https://huggingface.co/models?library=coreml&sort=downloads&search=whisperkit%20whisper"
    ) else { return }
    NSWorkspace.shared.open(url)
  }

  #if !APP_STORE
  private func openLocalStreamingModelSearch() {
    guard let url = URL(
      string: "https://huggingface.co/models?pipeline_tag=automatic-speech-recognition&sort=downloads"
        + "&search=sherpa-onnx%20streaming"
    ) else { return }
    NSWorkspace.shared.open(url)
  }
  #endif

  private func installHuggingFaceModel() {
    do {
      let model = try localModels.importHuggingFaceModel(
        repoID: huggingFaceRepoID,
        modelName: huggingFaceModelName
      )
      huggingFaceImportError = nil
      Task { await localModels.install(model) }
    } catch {
      huggingFaceImportError = error.localizedDescription
    }
  }

  #if !APP_STORE
  private func addStreamingModelSource() {
    do {
      _ = try localModels.addStreamingModelSource(
        repoID: streamingHuggingFaceRepoID,
        modelName: streamingHuggingFaceModelName
      )
      streamingHuggingFaceImportError = nil
    } catch {
      streamingHuggingFaceImportError = error.localizedDescription
    }
  }

  private func addSelectedStreamingModelSource() {
    guard let source = selectedRecommendedStreamingSource else { return }
    do {
      _ = try localModels.addStreamingModelSource(source)
      streamingHuggingFaceImportError = nil
    } catch {
      streamingHuggingFaceImportError = error.localizedDescription
    }
  }
  #endif

  private func firstInstalledStreamingSourceID(excluding excludedID: String? = nil) -> String? {
    if FluidAudioParakeetModel.id != excludedID, fluidAudioModels.installState == .installed {
      return FluidAudioParakeetModel.id
    }
    if let whisperKitModel = localStreamingModels.first(where: {
      let streamingID = WhisperKitStreamingModel.id(for: $0)
      return streamingID != excludedID && localModels.isInstalled($0.id)
    }) {
      return WhisperKitStreamingModel.id(for: whisperKitModel)
    }
    #if !APP_STORE
    return localModels.streamingModelSources.first {
      $0.id != excludedID && (sherpaRuntime.modelStates[$0.id] ?? .notInstalled) == .installed
    }?.id
    #else
    return nil
    #endif
  }

  private func firstInstalledLocalTranscriptionModelID(excluding excludedID: String? = nil) -> String? {
    localModels.availableModels.first {
      $0.id != excludedID && localModels.isInstalled($0.id)
    }?.id
  }

  private func localModelSizeLabel(for model: LocalTranscriptionModel) -> String {
    guard model.approximateSizeMB > 0 else {
      return "\(model.engine.displayName) · size confirmed during download"
    }
    return "\(model.engine.displayName) · ~\(model.approximateSizeMB) MB"
  }

  private func selectedLocalModelStatusIcon(for state: LocalModelManager.InstallState) -> String {
    switch state {
    case .installed:
      return settings.transcriptionMode == .localModel ? "checkmark.circle.fill" : "switch.2"
    case .installing:
      return "arrow.down.circle.fill"
    case .notInstalled:
      return "arrow.down.circle"
    case .failed:
      return "exclamationmark.triangle.fill"
    }
  }

  private func selectedLocalModelStatusTitle(
    for state: LocalModelManager.InstallState,
    model: LocalTranscriptionModel
  ) -> String {
    switch state {
    case .installed:
      if settings.localTranscriptionMode == .streaming, !model.supportsLiveStreaming {
        return "\(model.displayName) is offline-only"
      }
      return settings.transcriptionMode == .localModel
        ? "\(model.displayName) is ready"
        : "\(model.displayName) is downloaded"
    case .installing:
      return "Downloading \(model.displayName)"
    case .notInstalled:
      return "Download \(model.displayName)"
    case .failed:
      return "Download failed"
    }
  }

  private func selectedLocalModelStatusDetail(
    for state: LocalModelManager.InstallState,
    model: LocalTranscriptionModel
  ) -> String {
    switch state {
    case .installed:
      if settings.localTranscriptionMode == .streaming, !model.supportsLiveStreaming {
        return "This model can transcribe after recording stops, but it cannot stream live."
      }
      return settings.transcriptionMode == .localModel
        ? "Hold your recording shortcut; transcription runs locally when you stop."
        : "Switch to Local Model mode to run this model instead of a cloud provider."
    case .installing:
      return "Keep Settings open while the model download finishes."
    case .notInstalled:
      return "Download once, then this Mac can transcribe with it offline."
    case .failed(let message):
      return message
    }
  }

  private func localModelIcon(for state: LocalModelManager.InstallState) -> String {
    switch state {
    case .installed:
      return "checkmark.circle.fill"
    case .installing:
      return "arrow.down.circle.fill"
    case .notInstalled:
      return "icloud.and.arrow.down"
    case .failed:
      return "exclamationmark.triangle.fill"
    }
  }

  private func localModelTint(for state: LocalModelManager.InstallState) -> Color {
    switch state {
    case .installed:
      return .green
    case .installing:
      return .brandLagoon
    case .notInstalled:
      return .secondary
    case .failed:
      return .red
    }
  }

}
