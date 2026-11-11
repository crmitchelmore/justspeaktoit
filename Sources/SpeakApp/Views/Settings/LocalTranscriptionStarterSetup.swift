import SpeakCore
import AppKit
import SwiftUI

/// Ready-made local transcription setups that select a mode and download its model.
struct LocalTranscriptionStarterSetup: View, LocalModelRowPresenting {
  enum InstallState: Equatable {
    case notInstalled
    case installing
    case installed
    case failed(String)
  }

  @EnvironmentObject var settings: AppSettings
  @ObservedObject var localModels = LocalModelManager.shared
  @ObservedObject var fluidAudioModels = FluidAudioModelManager.shared
  @Binding var activationTask: Task<Void, Never>?

  var body: some View {
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
              ? "Choose fast English streaming, multilingual accuracy, or a smaller download."
              : "Choose English accuracy, multilingual quality, or a smaller download for finished recordings."
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
          if preset.id == .phononBatch { phononAttribution }
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
    case .whisperKit, .phonon:
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
      availableModels: localModels.availableModels,
      supportsParakeet: FluidAudioModelManager.supportsCurrentHardware
    )
  }

  private func starterPresetInstallState(
    for preset: LocalTranscriptionStarterPreset
  ) -> InstallState {
    switch preset.engine {
    case .parakeet:
      switch fluidAudioModels.installState {
      case .notInstalled: return .notInstalled
      case .installing: return .installing
      case .installed: return .installed
      case .failed(let message): return .failed(message)
      }
    case .whisperKit(let model), .phonon(let model):
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
    case .whisperKit(let model), .phonon(let model):
      if preset.mode == .streaming {
        return settings.localStreamingModelSource == WhisperKitStreamingModel.id(for: model)
      }
      return settings.localTranscriptionModel == model.id
    }
  }

  /// Stages a preset, then makes it the active setup only after the model is ready.
  ///
  /// The previous setup keeps recording while the download runs, so a failed or
  /// cancelled download leaves the last usable model selected. The row shows the
  /// failure, which lets the user try again.
  private func configureAndDownload(_ preset: LocalTranscriptionStarterPreset) {
    activationTask = StarterPresetActivation.configureAndDownload(
      isReady: starterPresetInstallState(for: preset) == .installed,
      supersedes: activationTask,
      prepare: { await installStarterPreset(preset) },
      activate: { preset.activate(in: settings) }
    )
  }

  /// Downloads and prepares the model behind a preset.
  ///
  /// - Returns: `true` only when the model manager reports the model as installed.
  private func installStarterPreset(_ preset: LocalTranscriptionStarterPreset) async -> Bool {
    switch preset.engine {
    case .parakeet:
      await fluidAudioModels.install()
      return fluidAudioModels.installState == .installed
    case .whisperKit(let model), .phonon(let model):
      await localModels.install(model)
      return localModels.isInstalled(model.id)
    }
  }

  private func starterPresetIcon(for preset: LocalTranscriptionStarterPreset) -> String {
    switch preset.engine {
    case .parakeet: return "waveform.badge.mic"
    case .whisperKit, .phonon: return preset.mode == .streaming ? "waveform" : "doc.text.magnifyingglass"
    }
  }

  private func starterPresetActionTitle(
    for state: InstallState,
    isSelected: Bool
  ) -> String {
    switch state {
    case .installed: return isSelected ? "Configured" : "Use This Setup"
    case .installing: return "Configuring"
    case .notInstalled, .failed: return "Configure and Download"
    }
  }

  private func starterPresetStatusText(
    for state: InstallState,
    isSelected: Bool
  ) -> String {
    switch state {
    case .installed: return isSelected ? "Configured and ready" : "Downloaded and ready to select"
    case .installing: return "Downloading and preparing the model"
    case .notInstalled: return "Not downloaded"
    case .failed(let message): return "Download failed: \(message)"
    }
  }

  private func starterPresetStatusTint(for state: InstallState) -> Color {
    switch state {
    case .installed: return .green
    case .installing: return .orange
    case .notInstalled: return .secondary
    case .failed: return .red
    }
  }
}
