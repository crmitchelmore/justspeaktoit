import SwiftUI

/// A bundled catalogue option or a live-discovered OpenRouter transcription model.
enum OpenRouterTranscriptionBrowserItem: Identifiable {
    case bundled(ModelCatalog.Option)
    case discovered(OpenRouterAudioModel)

    var id: String {
        switch self {
        case .bundled(let option): return option.id
        case .discovered(let model): return model.transcriptionSelectionID
        }
    }
}

/// The OpenRouter level of the batch transcription picker, in the same discover-then-configure
/// flow as OpenRouter speech and cleanup: bundled OpenRouter models first, then the live
/// catalogue of dedicated speech-to-text models, each opening a detail page before it is chosen.
@MainActor
public struct OpenRouterTranscriptionBrowser: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog: OpenRouterAudioCatalog
    private let apiKeyProvider: @Sendable () async -> String?
    private let selection: String
    private let bundled: [ModelCatalog.Option]
    private let embedded: Bool
    private let onBack: (() -> Void)?
    private let onSelect: (String) -> Void

    /// - Parameter bundled: The host's batch options; only OpenRouter routes are listed.
    public init(
        apiKeyProvider: @escaping @Sendable () async -> String?,
        selection: String,
        bundled: [ModelCatalog.Option],
        embedded: Bool = false,
        onBack: (() -> Void)? = nil,
        onSelect: @escaping (String) -> Void
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.selection = selection
        self.bundled = OpenRouterCatalogOptions.models(from: bundled, purpose: .batchTranscription)
        self.embedded = embedded
        self.onBack = onBack
        self.onSelect = onSelect
        _catalog = StateObject(wrappedValue: OpenRouterAudioCatalog(apiKeyProvider: apiKeyProvider))
    }

    public var body: some View {
        OpenRouterModelBrowser(
            title: OpenRouterModelBrowserCatalog.title(for: .transcription),
            intro: OpenRouterModelBrowserCatalog.intro(for: .transcription),
            items: items,
            status: OpenRouterBrowserStatus(
                isRefreshing: catalog.isRefreshing, errorMessage: catalog.errorMessage,
                lastUpdated: catalog.lastUpdated, isStale: catalog.isStale, missingSelection: missingSelection
            ),
            canRefresh: true,
            embedded: embedded,
            searchText: searchText,
            provider: provider,
            hasZeroPrices: hasZeroPrices,
            name: name,
            subtitle: subtitle,
            isSelected: { $0.id.caseInsensitiveCompare(selection) == .orderedSame },
            refresh: { force in await catalog.refresh(force: force) },
            onBack: onBack,
            header: { EmptyView() },
            detail: { item in
                switch item {
                case .bundled(let option):
                    OpenRouterOptionDetail(
                        option: option,
                        purpose: .batchTranscription,
                        actionTitle: OpenRouterModelBrowserCatalog.actionTitle(for: .transcription, selected: false),
                        selectedTitle: OpenRouterModelBrowserCatalog.actionTitle(for: .transcription, selected: true),
                        routeNote: OpenRouterModelBrowserCatalog.routeNote(for: .transcription),
                        isSelected: item.id.caseInsensitiveCompare(selection) == .orderedSame,
                        onSelect: choose
                    )
                case .discovered(let model):
                    OpenRouterAudioModelDetail(
                        model: model, capability: .transcription,
                        apiKeyProvider: apiKeyProvider, selectedSpeechID: nil, onSelect: choose
                    )
                }
            }
        )
    }

    private var items: [OpenRouterTranscriptionBrowserItem] {
        bundled.map(OpenRouterTranscriptionBrowserItem.bundled)
            + catalog.models(for: .transcription).sorted { $0.name < $1.name }
                .map(OpenRouterTranscriptionBrowserItem.discovered)
    }

    private func choose(_ identifier: String) {
        onSelect(identifier)
        dismiss()
    }

    private func name(_ item: OpenRouterTranscriptionBrowserItem) -> String {
        switch item {
        case .bundled(let option): return option.displayName
        case .discovered(let model): return model.name
        }
    }

    private func subtitle(_ item: OpenRouterTranscriptionBrowserItem) -> String {
        switch item {
        case .bundled(let option): return "Bundled · \(option.id)"
        case .discovered(let model): return "Discovered · \(model.id)"
        }
    }

    private func searchText(_ item: OpenRouterTranscriptionBrowserItem) -> [String] {
        switch item {
        case .bundled(let option):
            return OpenRouterCatalogOptions.searchText(for: option, purpose: .batchTranscription)
        case .discovered(let model):
            return OpenRouterAudioFilter.searchText(for: model) + [provider(item)]
        }
    }

    private func provider(_ item: OpenRouterTranscriptionBrowserItem) -> String {
        switch item {
        case .bundled(let option):
            return OpenRouterCatalogOptions.provider(for: option, purpose: .batchTranscription)
        case .discovered(let model):
            return OpenRouterCatalogOptions.vendorName(forModelSlug: model.id)
        }
    }

    private func hasZeroPrices(_ item: OpenRouterTranscriptionBrowserItem) -> Bool {
        switch item {
        case .bundled(let option): return OpenRouterCatalogOptions.hasZeroPrices(option)
        case .discovered(let model): return OpenRouterAudioFilter.hasZeroPrices(model)
        }
    }

    private var missingSelection: String? {
        guard let identifier = OpenRouterTranscriptionSelection.modelID(from: selection),
              catalog.lastUpdated != nil,
              !catalog.models(for: .transcription).contains(where: { $0.id == identifier }) else { return nil }
        return identifier
    }
}
