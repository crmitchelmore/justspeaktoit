#if os(iOS)
import SpeakCore
import SwiftUI

// MARK: - Post-processing model picker

/// Native and on-device cleanup models, the saved OpenRouter choice when there is one,
/// then a separate Browse OpenRouter models link to the shared discover-then-configure
/// browser, laid out like the voice and transcription pickers.
struct PostProcessingModelPickerRows: View {
    @ObservedObject var settings: AppSettings
    var showsDescriptions = true
    var onSelect: () -> Void = {}

    private var groups: ModelPickerGrouping.Groups {
        ModelPickerGrouping.groups(Self.options(selected: settings.postProcessingModel), purpose: .postProcessing)
    }

    /// The iOS catalogue plus discovered or saved OpenRouter choices.
    static func options(selected: String) -> [ModelCatalog.Option] {
        var options = AppSettings.postProcessingModels
        let bundled = Set(ModelCatalog.postProcessing.map(\.id))
        options += CleanupModelDiscoveryStore.shared.options(selected: selected)
            .filter { !bundled.contains($0.id) }
        return options
    }

    var body: some View {
        ForEach(groups.direct) { model in
            PostProcessingModelRow(
                settings: settings, model: model, showsDescription: showsDescriptions, onSelect: onSelect
            )
        }
        if let selected = groups.openRouter.first(where: { $0.id == settings.postProcessingModel }) {
            PostProcessingModelRow(
                settings: settings, model: selected, showsDescription: showsDescriptions,
                title: ModelPickerGrouping.selectionLabel(
                    for: selected.id, displayName: selected.displayName, purpose: .postProcessing
                ),
                onSelect: onSelect
            )
        }
        NavigationLink {
            OpenRouterCleanupBrowser(
                selection: settings.postProcessingModel,
                discoveryEnabled: $settings.cleanupModelDiscoveryEnabled,
                options: { Self.options(selected: settings.postProcessingModel) },
                embedded: true,
                onSelect: { identifier in
                    settings.postProcessingModel = identifier
                    onSelect()
                }
            )
        } label: {
            Label("Browse OpenRouter models…", systemImage: "network")
        }
        .accessibilityIdentifier("postProcessingModel.openRouter")
    }
}

private struct PostProcessingModelRow: View {
    @ObservedObject var settings: AppSettings
    let model: ModelCatalog.Option
    let showsDescription: Bool
    var title: String?
    let onSelect: () -> Void

    var body: some View {
        Button {
            settings.postProcessingModel = model.id
            onSelect()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title ?? model.displayName)
                        .foregroundStyle(.primary)
                    if showsDescription, let description = model.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                ModelCredentialStatusView(
                    availability: ModelCredentialResolver.availability(
                        for: model.id,
                        purpose: .postProcessing,
                        storedAPIKeyIdentifiers: settings.storedAPIKeyIdentifiers
                    )
                )

                if settings.postProcessingModel == model.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}
#endif
