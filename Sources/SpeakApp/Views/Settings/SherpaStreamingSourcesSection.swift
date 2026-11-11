import SpeakCore
import AppKit
import SwiftUI

#if !APP_STORE
/// The optional sherpa-onnx runtime and the streaming sources it can run.
struct SherpaStreamingSourcesSection: View, LocalModelRowPresenting {
  @EnvironmentObject var settings: AppSettings
  @ObservedObject var localModels = LocalModelManager.shared
  @ObservedObject var fluidAudioModels = FluidAudioModelManager.shared
  @ObservedObject var sherpaRuntime = SherpaOnnxRuntimeManager.shared
  @State private var streamingHuggingFaceRepoID: String =
    "csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26"
  @State private var streamingHuggingFaceModelName: String = "streaming-zipformer-en-2023-06-26"
  @State private var selectedRecommendedStreamingSourceID: String =
    LocalModelManager.recommendedStreamingModelSources.first?.id ?? ""
  @State private var streamingHuggingFaceImportError: String?

  private var inventory: LocalTranscriptionModelInventory {
    LocalTranscriptionModelInventory(
      settings: settings, localModels: localModels, fluidAudioModels: fluidAudioModels, sherpaRuntime: sherpaRuntime
    )
  }

  @ViewBuilder
  var body: some View {
    localStreamingRuntimeControls

    localStreamingSetupSection(
      title: "3. Add an optional sherpa-onnx model",
      subtitle: "Pick one of the compatible external-runtime models we know how to download and run locally.",
      systemImage: "checklist",
      tint: .orange
    ) {
      LongListPicker(
        title: "Available local streaming candidates", items: LocalModelManager.recommendedStreamingModelSources,
        id: { $0.id }, selection: $selectedRecommendedStreamingSourceID,
        searchText: { [$0.modelName, $0.id] },
        row: { source in
        Text("\(source.modelName) (\(localStreamingSizeLabel(for: source)))")
      })
      .labelsHidden()
      .settingsMenuPicker()
      if let source = selectedRecommendedStreamingSource {
        Text("\(source.runtime) · \(localStreamingSizeLabel(for: source)) · local-only streaming.")
          .font(.caption)
          .foregroundStyle(.secondary)
        if source.id == ParakeetLocalModels.tdtV3Int8SourceID {
          Text(ParakeetLocalModels.tdtV3SettingsSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if NemotronLocalModels.isMultilingual(source.modelName) {
          Text(NemotronLocalModels.settingsSummary)
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
  }
}

private extension SherpaStreamingSourcesSection {
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
            if let fallback = inventory.firstInstalledStreamingSourceID(excluding: source.id) {
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
        if sherpaRuntime.runtimeUpdateAvailable {
          Button("Update Runtime") {
            Task { await sherpaRuntime.installRuntime() }
          }
          .speakTooltip("Install sherpa-onnx \(SherpaOnnxRuntimeManager.pinnedRuntimeVersion), needed by Nemotron 3.5.")
        } else {
          Text("Installed")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
        }
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
      if sherpaRuntime.runtimeUpdateAvailable {
        return "Installed \(sherpaRuntime.installedRuntimeVersion ?? "runtime") is older than "
          + "\(SherpaOnnxRuntimeManager.pinnedRuntimeVersion); existing models still work."
      }
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

  private var canAddStreamingModelSource: Bool {
    streamingHuggingFaceRepoID.split(separator: "/").count == 2
      && !streamingHuggingFaceModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var selectedRecommendedStreamingSource: LocalStreamingModelSource? {
    LocalModelManager.recommendedStreamingModelSources.first {
      $0.id == selectedRecommendedStreamingSourceID
    } ?? LocalModelManager.recommendedStreamingModelSources.first
  }

  private func openLocalStreamingModelSearch() {
    guard let url = URL(
      string: "https://huggingface.co/models?pipeline_tag=automatic-speech-recognition&sort=downloads"
        + "&search=sherpa-onnx%20streaming"
    ) else { return }
    NSWorkspace.shared.open(url)
  }

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
}
#endif
