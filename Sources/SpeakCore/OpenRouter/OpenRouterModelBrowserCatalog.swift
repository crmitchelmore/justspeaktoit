import Foundation

/// One row of an OpenRouter model browser, carrying everything its details page shows.
/// Portable so hosts without SwiftUI (Windows, Linux) list, filter and describe models
/// with the same rules as the Apple browsers.
public struct OpenRouterBrowserItem: Identifiable, Equatable, Sendable {
    public enum Origin: String, Sendable {
        /// A bundled catalogue model, tested for its purpose.
        case bundled
        /// A model from OpenRouter's live catalogue (or a saved discovery).
        case discovered
    }

    /// The saved selection: a bundled ID, `openrouter/cleanup/…` or `openrouter/transcription/…`.
    public let id: String
    /// The OpenRouter model slug the request is sent as, e.g. "openai/gpt-5-mini".
    public let slug: String
    public let name: String
    public let summary: String
    /// The vendor the model is filed under ("OpenAI"), never OpenRouter itself.
    public let provider: String
    public let origin: Origin
    /// Per-million-token rates, when listed.
    public let pricing: ModelCatalog.Pricing?
    /// A discovered audio model's listed rates, with the provider's own keys and decimal strings.
    public let listedPrices: [String: String]
    public let contextLength: Int?
    /// Only listed zero prices count; a missing price is unknown, not free.
    public let hasZeroPrices: Bool
    /// Discovered cleanup models have not been tested for cleanup.
    public let isUnqualifiedDiscovery: Bool
    public let searchText: [String]
    /// The secondary line of a browser row.
    public let subtitle: String

    /// OpenRouter's public page for the model, when the slug is a valid `vendor/model`.
    public var modelPageURL: URL? { OpenRouterCatalogOptions.modelPageURL(for: id) }

    /// The chosen-row label, e.g. "OpenRouter › GPT-6 Luna".
    public var selectionLabel: String { OpenRouterModelBrowserCatalog.selectionLabel(name: name) }
}

/// The discover-then-configure OpenRouter browser's data, copy and rules, shared by every
/// platform: model pickers list native-provider models first, then a separate
/// **Browse OpenRouter models…** button opens a searchable list whose rows open a details
/// page before the model is chosen. Android ports these rules in `OpenRouterBrowser.kt`.
public enum OpenRouterModelBrowserCatalog {
    public enum Purpose: String, Sendable {
        case cleanup
        case transcription
    }

    public static let browseButtonTitle = "Browse OpenRouter models…"
    /// Shown by streaming pickers, which never list OpenRouter models.
    public static let streamingNote = "OpenRouter models can't stream; choose Remote Batch to use one."
    public static let searchPlaceholder = "Search models"
    public static let allProvidersTitle = "All providers"
    public static let zeroPricesTitle = "Zero listed prices"
    public static let emptyResults = "No matching models. Change the filters or refresh the catalogue."
    public static let pricingCaveat = "Base prices can vary by context and provider; check OpenRouter before use."
    public static let pricingUnlisted = "Pricing is not listed for this model."
    public static let unqualifiedWarning = "Discovered model: not yet tested for cleanup."
    public static let discoveryNote = "Discovery downloads public model details only. No key or transcript is sent. "
        + "Turning it off keeps your saved model; bundled models remain available offline."

    /// Live discovery endpoints. Cleanup discovery filters the whole catalogue with
    /// `CleanupModelDiscovery`'s rules; transcription asks only for speech-to-text models.
    public static let cleanupModelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
    public static let transcriptionModelsURL =
        URL(string: "https://openrouter.ai/api/v1/models?output_modalities=transcription")!

    public static func title(for purpose: Purpose) -> String {
        switch purpose {
        case .cleanup: return "OpenRouter cleanup models"
        case .transcription: return "OpenRouter transcription models"
        }
    }

    public static func intro(for purpose: Purpose) -> String {
        switch purpose {
        case .cleanup:
            return "Use your OpenRouter key for transcript cleanup. Bundled models are tested for cleanup; "
                + "discovered models are not."
        case .transcription:
            return "Use your OpenRouter key for batch transcription. Bundled models are listed first; "
                + "browsing downloads model metadata only."
        }
    }

    public static func actionTitle(for purpose: Purpose, selected: Bool) -> String {
        switch (purpose, selected) {
        case (.cleanup, false): return "Use for cleanup"
        case (.cleanup, true): return "Selected for cleanup"
        case (.transcription, false): return "Use for transcription"
        case (.transcription, true): return "Selected for transcription"
        }
    }

    public static func routeNote(for purpose: Purpose) -> String {
        switch purpose {
        case .cleanup: return "Cleanup requests for this model are sent to OpenRouter with your OpenRouter key."
        case .transcription: return "Recordings for this model are sent to OpenRouter with your OpenRouter key."
        }
    }

    public static func selectionLabel(name: String) -> String {
        ModelPickerGrouping.openRouterTitle + ModelPickerGrouping.openRouterSeparator + name
    }

    /// The OpenRouter-routed cleanup options (bundled, discovered and a retained saved
    /// discovery), in the shared vendor-then-name order. Native routes are not listed.
    public static func cleanupItems(options: [ModelCatalog.Option]) -> [OpenRouterBrowserItem] {
        OpenRouterCatalogOptions.models(from: options, purpose: .postProcessing).map { option in
            let slug = OpenRouterCatalogOptions.modelSlug(for: option.id)
            return item(
                option, purpose: .postProcessing, slug: slug,
                origin: OpenRouterCatalogOptions.isUnqualifiedDiscovery(option) ? .discovered : .bundled,
                subtitle: [slug, option.pricing?.displayName].compactMap { $0 }.joined(separator: " · ")
            )
        }
    }

    /// Bundled OpenRouter batch options first, then live speech-to-text models by name.
    /// A discovered model that duplicates a listed selection is dropped.
    public static func transcriptionItems(
        bundled: [ModelCatalog.Option], discovered: [OpenRouterAudioModel]
    ) -> [OpenRouterBrowserItem] {
        let bundledItems = OpenRouterCatalogOptions.models(from: bundled, purpose: .batchTranscription).map {
            item($0, purpose: .batchTranscription, slug: OpenRouterCatalogOptions.modelSlug(for: $0.id),
                 origin: .bundled, subtitle: "Bundled · \($0.id)")
        }
        var seen = Set(bundledItems.map { $0.id.lowercased() })
        let discoveredItems = discovered
            .filter { $0.supports(.transcription) && seen.insert($0.transcriptionSelectionID.lowercased()).inserted }
            .sorted { lhs, rhs in
                ModelPickerGrouping.ordered(lhs.name, rhs.name) ?? (lhs.id < rhs.id)
            }
            .map(item)
        return bundledItems + discoveredItems
    }

    public static func filtered(
        _ items: [OpenRouterBrowserItem], by filter: OpenRouterBrowserFilter
    ) -> [OpenRouterBrowserItem] {
        items.filter {
            filter.matches(searchText: $0.searchText, provider: $0.provider, hasZeroPrices: $0.hasZeroPrices)
        }
    }

    /// The provider filter's choices, alphabetical and without duplicates.
    public static func providers(in items: [OpenRouterBrowserItem]) -> [String] {
        Array(Set(items.map(\.provider))).sorted { ModelPickerGrouping.ordered($0, $1) ?? ($0 < $1) }
    }

    /// A saved `openrouter/transcription/…` model that a loaded live catalogue no longer lists.
    public static func missingTranscriptionSelection(
        _ selection: String, discovered: [OpenRouterAudioModel], catalogueLoaded: Bool
    ) -> String? {
        guard catalogueLoaded, let identifier = OpenRouterTranscriptionSelection.modelID(from: selection),
              !discovered.contains(where: { $0.supports(.transcription) && $0.id == identifier }) else { return nil }
        return identifier
    }

    private static func item(
        _ option: ModelCatalog.Option, purpose: ModelCredentialPurpose, slug: String,
        origin: OpenRouterBrowserItem.Origin, subtitle: String
    ) -> OpenRouterBrowserItem {
        OpenRouterBrowserItem(
            id: option.id, slug: slug, name: option.displayName, summary: option.description ?? "",
            provider: OpenRouterCatalogOptions.provider(for: option, purpose: purpose), origin: origin,
            pricing: option.pricing, listedPrices: [:], contextLength: option.contextLength,
            hasZeroPrices: OpenRouterCatalogOptions.hasZeroPrices(option),
            isUnqualifiedDiscovery: OpenRouterCatalogOptions.isUnqualifiedDiscovery(option),
            searchText: OpenRouterCatalogOptions.searchText(for: option, purpose: purpose),
            subtitle: subtitle
        )
    }

    private static func item(_ model: OpenRouterAudioModel) -> OpenRouterBrowserItem {
        let provider = OpenRouterCatalogOptions.vendorName(forModelSlug: model.id)
        return OpenRouterBrowserItem(
            id: model.transcriptionSelectionID, slug: model.id, name: model.name, summary: model.description,
            provider: provider, origin: .discovered, pricing: nil, listedPrices: model.pricing,
            contextLength: model.contextLength, hasZeroPrices: OpenRouterAudioFilter.hasZeroPrices(model),
            isUnqualifiedDiscovery: false,
            searchText: OpenRouterAudioFilter.searchText(for: model) + [provider],
            subtitle: "Discovered · \(model.id)"
        )
    }
}
