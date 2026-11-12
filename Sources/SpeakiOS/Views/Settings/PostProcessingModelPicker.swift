#if os(iOS)
import SpeakCore
import SwiftUI

// MARK: - Post-processing model picker

/// Native and on-device cleanup models first, then one OpenRouter row that opens
/// the shared discover-then-configure OpenRouter browser. Grouping comes from the shared
/// `ModelPickerGrouping`, so the list always reflects the route a model uses.
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
        if !groups.openRouter.isEmpty {
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
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ModelPickerGrouping.openRouterTitle)
                            .foregroundStyle(.primary)
                        Text(openRouterSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ModelCredentialStatusView(
                        availability: ModelCredentialResolver.availability(
                            for: groups.openRouter[0].id,
                            purpose: .postProcessing,
                            storedAPIKeyIdentifiers: settings.storedAPIKeyIdentifiers
                        )
                    )
                    if isOpenRouterSelected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .accessibilityIdentifier("postProcessingModel.openRouter")
        }
    }

    private var isOpenRouterSelected: Bool {
        groups.openRouter.contains { $0.id == settings.postProcessingModel }
    }

    private var openRouterSubtitle: String {
        if let selected = groups.openRouter.first(where: { $0.id == settings.postProcessingModel }) {
            return selected.displayName
        }
        return "Choose from \(groups.openRouter.count) models with one OpenRouter key"
    }
}

private struct PostProcessingModelRow: View {
    @ObservedObject var settings: AppSettings
    let model: ModelCatalog.Option
    let showsDescription: Bool
    let onSelect: () -> Void

    var body: some View {
        Button {
            settings.postProcessingModel = model.id
            onSelect()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName)
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
