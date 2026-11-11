import SpeakCore
import AppKit
import SwiftUI

/// The built-in rules cleaner and every downloadable local post-processing model.
struct LocalPostProcessingModelList: View, LocalModelRowPresenting {
  @EnvironmentObject var settings: AppSettings
  @ObservedObject var localPostProcessingModels = LocalPostProcessingModelManager.shared

  var body: some View {
    VStack(spacing: 10) {
      ForEach(
        ModelCatalog.postProcessing.filter { $0.id == LocalPostProcessingModelManager.builtInRulesModelID }
      ) { option in
        builtInLocalPostProcessingRow(option)
      }
      #if !APP_STORE
      ForEach(localPostProcessingModels.availableModels) { model in
        localPostProcessingModelRow(model)
      }
      #endif
    }
  }
}

private extension LocalPostProcessingModelList {
  private func builtInLocalPostProcessingRow(_ option: ModelCatalog.Option) -> some View {
    let isSelected = PostProcessingManager.isLocalPostProcessingModel(settings.postProcessingModel)
      && settings.postProcessingModel.caseInsensitiveCompare(option.id) == .orderedSame
    return localModelRowContainer(isSelected: isSelected, tint: .green) {
      HStack(alignment: .top, spacing: 12) {
      Image(systemName: "wand.and.stars")
        .foregroundStyle(Color.green)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(option.displayName)
            .font(.subheadline.weight(.semibold))
          if isSelected {
            localModelBadge("Selected", tint: .green)
          }
          localModelBadge("Local", tint: .green)
          localModelBadge("Built in", tint: .secondary)
        }
        if let description = option.description {
          Text(description)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text("Ready now - 0 MB download - local only")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
      }

      Spacer()

      if isSelected {
        selectedModelBadge()
      } else {
        Button("Use") {
          settings.postProcessingModel = option.id
        }
      }
      }
    }
  }

  #if !APP_STORE
  // swiftlint:disable:next function_body_length
  private func localPostProcessingModelRow(_ model: LocalPostProcessingModel) -> some View {
      let state = localPostProcessingModels.installState(for: model.id)
      let isSelected = state == .installed
        && settings.postProcessingModel.caseInsensitiveCompare(model.id) == .orderedSame
      return localModelRowContainer(isSelected: isSelected, tint: .green) {
        HStack(alignment: .top, spacing: 12) {
        Image(systemName: localPostProcessingModelIcon(for: state))
          .foregroundStyle(localPostProcessingModelTint(for: state))
          .frame(width: 24)

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(model.displayName)
              .font(.subheadline.weight(.semibold))
            if isSelected {
              localModelBadge("Selected", tint: .green)
            }
            localModelBadge("Hugging Face", tint: Color.brandAccentDeep)
          }
          Text(model.description)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("\(model.sizeLabel) - \(model.repoID) / \(model.filename)")
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
                settings.postProcessingModel = model.id
              }
            }
            Button("Delete") {
              localPostProcessingModels.deleteModel(model)
              if settings.postProcessingModel.caseInsensitiveCompare(model.id) == .orderedSame {
                settings.postProcessingModel = LocalPostProcessingModelManager.builtInRulesModelID
              }
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
          VStack(alignment: .trailing, spacing: 8) {
            Button("Download") {
              Task { await localPostProcessingModels.installModel(model) }
            }
          }
        }
      }
    }
  }

  private func localPostProcessingModelIcon(for state: LocalPostProcessingModelManager.InstallState) -> String {
    switch state {
    case .installed: return "checkmark.circle.fill"
    case .installing: return "arrow.down.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    case .notInstalled: return "externaldrive.badge.plus"
    }
  }

  private func localPostProcessingModelTint(for state: LocalPostProcessingModelManager.InstallState) -> Color {
    switch state {
    case .installed: return .green
    case .installing: return .brandAccentDeep
    case .failed: return .red
    case .notInstalled: return .secondary
    }
  }
  #endif
}
