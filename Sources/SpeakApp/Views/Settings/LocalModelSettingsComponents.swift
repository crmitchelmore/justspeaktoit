import SpeakCore
import AppKit
import SwiftUI

/// A settings view that edits `AppSettings` through plain bindings.
@MainActor
protocol AppSettingsBindingProviding {
  var settings: AppSettings { get }
}

extension AppSettingsBindingProviding {
  func settingsBinding<Value: Hashable>(
    _ keyPath: ReferenceWritableKeyPath<AppSettings, Value>
  ) -> Binding<Value> {
    Binding(
      get: { settings[keyPath: keyPath] },
      set: { settings[keyPath: keyPath] = $0 }
    )
  }

  func settingsToggle(_ label: String, isOn: Binding<Bool>, tint: Color) -> some View {
    Toggle(label, isOn: isOn)
      .tint(tint)
      .settingsControlChrome()
  }
}

/// Row chrome shared by the local transcription and post-processing model lists.
@MainActor
protocol LocalModelRowPresenting {}

extension LocalModelRowPresenting {
  func localModelBadge(_ title: String, tint: Color) -> some View {
    Text(title)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(Capsule().fill(tint.opacity(0.12)))
  }

  func selectedModelBadge(tint: Color = .green) -> some View {
    Label("Selected", systemImage: "checkmark.circle.fill")
      .font(.caption.weight(.semibold))
      .foregroundStyle(tint)
  }

  func localModelRowContainer<Content: View>(
    isSelected: Bool,
    tint: Color,
    @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(isSelected ? tint.opacity(0.13) : Color(nsColor: .controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(isSelected ? tint.opacity(0.8) : Color.clear, lineWidth: isSelected ? 2 : 0)
      )
      .shadow(color: isSelected ? tint.opacity(0.16) : .clear, radius: 10, y: 3)
  }

  var phononAttribution: some View {
    HStack {
      Link("Model & attribution", destination: URL(string: "https://huggingface.co/FermionResearch/Phonon-2")!)
      Link("CC-BY-4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
    }
    .font(.caption2)
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
        .foregroundStyle(SpeakTextStyle.onTint)
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

  func localStreamingSetupSection<Content: View>(
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

  func localModelSizeLabel(for model: LocalTranscriptionModel) -> String {
    guard model.approximateSizeMB > 0 else {
      return "\(model.engine.displayName) · size confirmed during download"
    }
    return "\(model.engine.displayName) · ~\(model.approximateSizeMB) MB"
  }

  func localModelIcon(for state: LocalModelManager.InstallState) -> String {
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

  func localModelTint(for state: LocalModelManager.InstallState) -> Color {
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

/// Which downloaded transcription models are installed, and the selection
/// repair that follows deleting one.
@MainActor
struct LocalTranscriptionModelInventory {
  let settings: AppSettings
  let localModels: LocalModelManager
  let fluidAudioModels: FluidAudioModelManager
  #if !APP_STORE
  let sherpaRuntime: SherpaOnnxRuntimeManager
  #endif

  var streamingModels: [LocalTranscriptionModel] {
    localModels.availableModels.filter(\.supportsLiveStreaming)
  }

  /// Installed models offered by the Local Batch model picker.
  var installedTranscriptionOptions: [ModelCatalog.Option] {
    localModels.availableModels
      .filter { localModels.isInstalled($0.id) }
      .map(\.option)
  }

  func firstInstalledStreamingSourceID(excluding excludedID: String? = nil) -> String? {
    if FluidAudioParakeetModel.id != excludedID, fluidAudioModels.installState == .installed {
      return FluidAudioParakeetModel.id
    }
    if let whisperKitModel = streamingModels.first(where: {
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

  func firstInstalledLocalTranscriptionModelID(excluding excludedID: String? = nil) -> String? {
    localModels.availableModels.first {
      $0.id != excludedID && localModels.isInstalled($0.id)
    }?.id
  }

  func deleteDownloadedWhisperKitModel(_ model: LocalTranscriptionModel) {
    guard localModels.delete(model) else { return }
    let sourceID = WhisperKitStreamingModel.id(for: model)
    settings.repairRemovedWhisperKitSelection(
      modelID: model.id, streamingSourceID: sourceID,
      fallbackBatchModelID: firstInstalledLocalTranscriptionModelID(excluding: model.id),
      fallbackStreamingSourceID: firstInstalledStreamingSourceID(excluding: sourceID)
    )
  }
}

extension LocalPostProcessingModelManager {
  /// Local post-processing models offered by the picker: the built-in rules
  /// cleaner plus any downloaded model.
  var settingsPickerOptions: [ModelCatalog.Option] {
    let builtIn = ModelCatalog.postProcessing.filter {
      PostProcessingManager.isLocalPostProcessingModel($0.id)
    }
    #if APP_STORE
    return builtIn
    #else
    let downloaded = availableModels
      .filter { isInstalled($0.id) }
      .map(\.option)
    return builtIn + downloaded
    #endif
  }
}
