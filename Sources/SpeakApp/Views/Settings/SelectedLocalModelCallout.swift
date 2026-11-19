import SpeakCore
import AppKit
import SwiftUI

/// Status and next action for the selected local batch model.
struct SelectedLocalModelCallout: View, LocalModelRowPresenting {
  @EnvironmentObject var settings: AppSettings
  @ObservedObject var localModels = LocalModelManager.shared

  @ViewBuilder
  var body: some View {
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
    localModels.availableModels.first { $0.id == settings.localTranscriptionModel }
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
}
