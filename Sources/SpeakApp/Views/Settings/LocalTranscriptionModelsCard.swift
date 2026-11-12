import SpeakCore
import AppKit
import SwiftUI

/// Downloaded WhisperKit / FluidAudio / sherpa-onnx models for local transcription.
struct LocalTranscriptionModelsCard: View, LocalModelRowPresenting {
  @EnvironmentObject var settings: AppSettings
  @ObservedObject var localModels = LocalModelManager.shared
  @ObservedObject var fluidAudioModels = FluidAudioModelManager.shared
  #if !APP_STORE
  @ObservedObject var sherpaRuntime = SherpaOnnxRuntimeManager.shared
  #endif
  /// Owned by the settings page so a newer preset download always supersedes
  /// an older one, even after this card is rebuilt.
  @Binding var starterPresetActivationTask: Task<Void, Never>?
  @State private var huggingFaceRepoID: String = "argmaxinc/whisperkit-coreml"
  @State private var huggingFaceModelName: String = "tiny"
  @State private var huggingFaceImportError: String?
  @State private var isLocalTranscriptionAdvancedExpanded = false

  private var inventory: LocalTranscriptionModelInventory {
    #if APP_STORE
    LocalTranscriptionModelInventory(
      settings: settings, localModels: localModels, fluidAudioModels: fluidAudioModels
    )
    #else
    LocalTranscriptionModelInventory(
      settings: settings, localModels: localModels, fluidAudioModels: fluidAudioModels, sherpaRuntime: sherpaRuntime
    )
    #endif
  }

  var body: some View {
    SettingsCard(
      title: "Local transcription models",
      systemImage: "externaldrive.badge.checkmark",
      tint: Color.green
    ) {
      VStack(alignment: .leading, spacing: 16) {
        SettingsModeBadge(
          title: settings.localTranscriptionMode == .batch
            ? "Local Batch - private on this Mac"
            : "Local Streaming - private on this Mac",
          systemImage: "lock.shield.fill",
          tint: Color.green
        )

        Text(
          "Choose a ready-made setup below. Speak will select the right local mode "
            + "and download everything it needs."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        LocalTranscriptionStarterSetup(activationTask: $starterPresetActivationTask)

        DisclosureGroup(isExpanded: $isLocalTranscriptionAdvancedExpanded) {
          VStack(alignment: .leading, spacing: 16) {
            Text(
              {
                #if APP_STORE
                """
                Downloaded transcription is separate from Apple Speech and cloud providers. \
                WhisperKit/Core ML model data runs in-process and is supported in this App Store build.
                """
                #else
                """
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
              SelectedLocalModelCallout()
              huggingFaceModelImport
            } else {
              LocalStreamingModelsSection()
            }

            if settings.localTranscriptionMode == .batch {
              if inventory.installedTranscriptionOptions.isEmpty {
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
                  options: inventory.installedTranscriptionOptions,
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
}

private extension LocalTranscriptionModelsCard {
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
          ? "Downloaded models transcribe locally after recording stops."
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
        if model.engine == .phonon { phononAttribution }
        Text(model.description)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(localModelSizeLabel(for: model))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
        if localModels.usesLegacyStorage(model) {
          Text("Removing this legacy installation keeps its shared cache. "
            + "Download again afterward to manage its storage.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
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
          Button(localModels.usesLegacyStorage(model) ? "Remove" : "Delete") {
            inventory.deleteDownloadedWhisperKitModel(model)
          }
          .disabled(!localModels.canDelete(model))
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
          if localModels.canDelete(model) {
            Button(state == .notInstalled ? "Delete" : "Retry Delete") {
              inventory.deleteDownloadedWhisperKitModel(model)
            }
          }
        }
      }
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

  private var localTranscriptionModels: [LocalTranscriptionModel] {
    localModels.availableModels
  }

  private var canImportHuggingFaceModel: Bool {
    HuggingFaceRepoInput.isValidRepoID(huggingFaceRepoID)
      && !huggingFaceModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func openHuggingFaceModelSearch() {
    guard let url = URL(
      string: "https://huggingface.co/models?library=coreml&sort=downloads&search=whisperkit%20whisper"
    ) else { return }
    NSWorkspace.shared.open(url)
  }

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
  private var localTranscriptionModelBinding: Binding<String> {
    Binding(
      get: {
        let options = inventory.installedTranscriptionOptions
        guard options.contains(where: { $0.id == settings.localTranscriptionModel }) else {
          return options.first?.id ?? ""
        }
        return settings.localTranscriptionModel
      },
      set: { model in
        guard inventory.installedTranscriptionOptions.contains(where: { $0.id == model }) else { return }
        settings.localTranscriptionModel = model
      }
    )
  }
}
