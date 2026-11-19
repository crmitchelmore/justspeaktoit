import SpeakCore
import AppKit
import SwiftUI

/// Local post-processing: the built-in rules cleaner and downloaded GGUF models.
struct LocalPostProcessingSection: View, LocalModelRowPresenting {
  @EnvironmentObject var settings: AppSettings
  @ObservedObject var localPostProcessingModels = LocalPostProcessingModelManager.shared
  #if !APP_STORE
  @State private var localPostProcessingRepoID: String = "unsloth/Qwen3-0.6B-GGUF"
  @State private var localPostProcessingFilename: String = "Qwen3-0.6B-Q4_K_M.gguf"
  @State private var localPostProcessingSizeMB: String = "450"
  @State private var localPostProcessingImportError: String?
  #endif

  private var localPostProcessingOptions: [ModelCatalog.Option] {
    localPostProcessingModels.settingsPickerOptions
  }

  private var localPostProcessingModelBinding: Binding<String> {
    Binding(
      get: {
        if PostProcessingManager.isLocalPostProcessingModel(settings.postProcessingModel) {
          guard localPostProcessingOptions.contains(where: { $0.id == settings.postProcessingModel }) else {
            return localPostProcessingOptions.first?.id ?? LocalPostProcessingModelManager.builtInRulesModelID
          }
          return settings.postProcessingModel
        }
        return localPostProcessingOptions.first?.id ?? LocalPostProcessingModelManager.builtInRulesModelID
      },
      set: { model in
        guard PostProcessingManager.isLocalPostProcessingModel(model),
          localPostProcessingOptions.contains(where: { $0.id == model })
        else { return }
        settings.postProcessingModel = model
      }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SettingsModeBadge(
        title: "Local Post-processing - private on this Mac",
        systemImage: "lock.shield.fill",
        tint: Color.green
      )

      #if APP_STORE
      Text(
        """
        Local post-processing is separate from OpenRouter and cloud LLMs. Use the built-in rules \
        model for instant cleanup with no downloaded runtime.
        """
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      #else
      Text(
        """
        Local post-processing is separate from OpenRouter and cloud LLMs. Use the built-in rules \
        model for instant cleanup, or download GGUF instruction models from Hugging Face for local LLM cleanup.
        """
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      #endif

      if !DistributionChannel.current.supportsExternalLocalModelRuntime {
        localRuntimeUnavailableNote
      }

      Label(
        """
        Small local models can ignore strict formatting or style instructions. For reliable prompt-following, \
        use a larger local instruction model or a remote post-processing model.
        """,
        systemImage: "exclamationmark.triangle"
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      localPostProcessingQuickStart
      #if !APP_STORE
      if !localPostProcessingModels.runtimeState.isInstalled {
        localPostProcessingRuntimeStatus
      }
      #endif

      #if APP_STORE
      ModelPicker(
        title: "Local Post-processing Model",
        help: "Used for local-only cleanup after transcription. Built-in rules need no runtime.",
        options: localPostProcessingOptions,
        value: localPostProcessingModelBinding,
        credentialPurpose: .postProcessing,
        storedAPIKeyIdentifiers: Set(settings.trackedAPIKeyIdentifiers),
        allowsCustom: false
      )
      #else
      ModelPicker(
        title: "Local Post-processing Model",
        help: """
        Used for local-only cleanup after transcription. Built-in rules need no runtime; \
        Hugging Face GGUF models need the local llama.cpp runtime and a model download.
        """,
        options: localPostProcessingOptions,
        value: localPostProcessingModelBinding,
        credentialPurpose: .postProcessing,
        storedAPIKeyIdentifiers: Set(settings.trackedAPIKeyIdentifiers),
        allowsCustom: false
      )
      #endif

      #if !APP_STORE
      localPostProcessingManualImport
      #endif

      LocalPostProcessingModelList()
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
}

private extension LocalPostProcessingSection {
  private var localPostProcessingQuickStart: some View {
    VStack(alignment: .leading, spacing: 8) {
      localModelStep(
        number: "1",
        title: "Choose Local",
        detail: "This switches transcript cleanup away from OpenRouter."
      )
      #if APP_STORE
      localModelStep(
        number: "2",
        title: "Use the built-in rules model",
        detail: "The built-in rules model stays available with no download or runtime."
      )
      localModelStep(
        number: "3",
        title: "Record normally",
        detail: "Speak runs built-in cleanup locally after transcription."
      )
      #else
      localModelStep(
        number: "2",
        title: "Download a local LLM model",
        detail: """
        GGUF models come from Hugging Face and show their approximate size before download. \
        The built-in rules model stays available with no download.
        """
      )
      localModelStep(
        number: "3",
        title: "Record normally",
        detail: "Speak runs cleanup locally after transcription. Downloaded models use the app-owned llama.cpp runtime."
      )
      #endif
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.green.opacity(0.08))
    )
  }

  #if !APP_STORE
  private var localPostProcessingRuntimeStatus: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: localPostProcessingRuntimeIcon)
        .foregroundStyle(localPostProcessingRuntimeTint)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 4) {
        Text("Local LLM runtime")
          .font(.subheadline.weight(.semibold))
        Text("Required only for downloaded Hugging Face GGUF models. Built-in cleanup works without it.")
          .font(.caption)
          .foregroundStyle(.secondary)
        if case .failed(let message) = localPostProcessingModels.runtimeState {
          Text(message)
            .font(.caption2)
            .foregroundStyle(.red)
        }
      }

      Spacer()

      switch localPostProcessingModels.runtimeState {
      case .installed:
        Text("Installed")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.green)
      case .installing:
        ProgressView()
          .controlSize(.small)
      case .notInstalled, .failed:
        Button("Install Runtime") {
          Task { await localPostProcessingModels.installRuntime() }
        }
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }

  private var localPostProcessingManualImport: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Add a Hugging Face GGUF model")
        .font(.caption.weight(.semibold))
      Text(
        """
        Use this for compatible llama.cpp/GGUF instruction models. Paste the Hugging Face repo and exact \
        .gguf filename; Speak will download and run it locally.
        """
      )
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack(spacing: 10) {
        TextField("Repo, e.g. unsloth/Qwen3-0.6B-GGUF", text: $localPostProcessingRepoID)
          .textFieldStyle(.roundedBorder)
        TextField("File, e.g. Qwen3-0.6B-Q4_K_M.gguf", text: $localPostProcessingFilename)
          .textFieldStyle(.roundedBorder)
      }
      HStack(spacing: 10) {
        TextField("Size MB (optional)", text: $localPostProcessingSizeMB)
          .textFieldStyle(.roundedBorder)
          .frame(width: 140)
        Button("Add Manual Model") {
          addLocalPostProcessingModel()
        }
        .buttonStyle(.bordered)
        Spacer()
      }
      if let localPostProcessingImportError {
        Text(localPostProcessingImportError)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }
  #endif

  #if !APP_STORE
  private var localPostProcessingRuntimeIcon: String {
    switch localPostProcessingModels.runtimeState {
    case .installed: return "checkmark.circle.fill"
    case .installing: return "arrow.down.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    case .notInstalled: return "shippingbox"
    }
  }

  private var localPostProcessingRuntimeTint: Color {
    switch localPostProcessingModels.runtimeState {
    case .installed: return .green
    case .installing: return .brandAccentDeep
    case .failed: return .red
    case .notInstalled: return .secondary
    }
  }

  private func addLocalPostProcessingModel() {
    localPostProcessingImportError = nil
    let size = Int(localPostProcessingSizeMB.trimmingCharacters(in: .whitespacesAndNewlines))
    do {
      _ = try localPostProcessingModels.addHuggingFaceModel(
        repoID: localPostProcessingRepoID,
        filename: localPostProcessingFilename,
        approximateSizeMB: size
      )
      localPostProcessingRepoID = ""
      localPostProcessingFilename = ""
      localPostProcessingSizeMB = ""
    } catch {
      localPostProcessingImportError = error.localizedDescription
    }
  }
  #endif
}
