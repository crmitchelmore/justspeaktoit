import SpeakCore
import AppKit
import SwiftUI

/// Switches post-processing between a remote model and a local one.
struct PostProcessingLocationPicker: View {
  @EnvironmentObject var settings: AppSettings
  @ObservedObject var localPostProcessingModels = LocalPostProcessingModelManager.shared

  private enum Location: String, CaseIterable, Identifiable {
    case remote
    case local

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .remote: return "Remote"
      case .local: return "Local"
      }
    }
  }

  var body: some View {
    HStack(spacing: 8) {
      ForEach(Location.allCases) { location in
        Button {
          postProcessingLocationBinding.wrappedValue = location
        } label: {
          Text(location.displayName)
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 8)
            .padding(.horizontal, 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(postProcessingLocationBinding.wrappedValue == location ? .white : .primary)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(postProcessingLocationBinding.wrappedValue == location ? Color.brandAccent : Color.clear)
        )
      }
    }
    .fixedSize()
    .padding(4)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }

  private var postProcessingLocationBinding: Binding<Location> {
    Binding(
      get: {
        PostProcessingManager.isLocalPostProcessingModel(settings.postProcessingModel) ? .local : .remote
      },
      set: { location in
        let currentLocation = PostProcessingManager.isLocalPostProcessingModel(settings.postProcessingModel)
          ? Location.local
          : .remote
        guard location != currentLocation else { return }
        selectLocation(location)
      }
    )
  }

  private func selectLocation(_ location: Location) {
    switch location {
    case .local:
      settings.postProcessingModel = localPostProcessingModels.settingsPickerOptions.first?.id
        ?? "local/post-processing/rules"
    case .remote:
      let cloudOptions = CleanupModelDiscoveryStore.shared.options(selected: settings.postProcessingModel)
      settings.postProcessingModel = cloudOptions.first {
        $0.id == ModelCatalog.defaultPostProcessingModel
      }?.id ?? cloudOptions.first?.id ?? settings.postProcessingModel
    }
  }
}
