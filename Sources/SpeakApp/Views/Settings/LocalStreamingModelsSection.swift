import SpeakCore
import AppKit
import SwiftUI

/// Local Streaming sources: Parakeet, WhisperKit and the optional sherpa-onnx runtime.
struct LocalStreamingModelsSection: View, LocalModelRowPresenting {
  @EnvironmentObject var settings: AppSettings
  @ObservedObject var localModels = LocalModelManager.shared
  @ObservedObject var fluidAudioModels = FluidAudioModelManager.shared
  #if !APP_STORE
  @ObservedObject var sherpaRuntime = SherpaOnnxRuntimeManager.shared
  #endif

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
      SherpaStreamingSourcesSection()
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
                  if let fallback = inventory.firstInstalledStreamingSourceID(excluding: FluidAudioParakeetModel.id) {
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
        ForEach(inventory.streamingModels) { model in
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
            Button(localModels.usesLegacyStorage(model) ? "Remove" : "Delete") {
              inventory.deleteDownloadedWhisperKitModel(model)
            }
            .disabled(!localModels.canDelete(model))
          case .installing:
            ProgressView()
              .controlSize(.small)
          case .notInstalled, .failed:
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

}
