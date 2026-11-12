import Foundation

/// What the OpenRouter level of a model picker lists and filters on for bundled
/// catalogue options. Native-provider routes stay in the picker's own list.
public enum OpenRouterCatalogOptions {
    /// The OpenRouter-routed options, in the shared vendor-then-name order.
    public static func models(
        from options: [ModelCatalog.Option], purpose: ModelCredentialPurpose
    ) -> [ModelCatalog.Option] {
        ModelPickerGrouping.groups(options, purpose: purpose).openRouter
    }

    /// The vendor a model is filed under ("OpenAI", "Anthropic"), not OpenRouter itself.
    public static func provider(for option: ModelCatalog.Option, purpose: ModelCredentialPurpose) -> String {
        ModelPickerGrouping.providerName(for: option.id, purpose: purpose)
    }

    public static func searchText(for option: ModelCatalog.Option, purpose: ModelCredentialPurpose) -> [String] {
        [option.displayName, option.id, option.description ?? "", provider(for: option, purpose: purpose)]
    }

    /// Only listed zero prices count; a missing price is unknown, not free.
    public static func hasZeroPrices(_ option: ModelCatalog.Option) -> Bool {
        guard let pricing = option.pricing else { return false }
        return pricing.promptPerMTokens == 0 && pricing.completionPerMTokens == 0
    }

    /// Discovered (or saved discovered) cleanup models have not been qualified for cleanup.
    public static func isUnqualifiedDiscovery(_ option: ModelCatalog.Option) -> Bool {
        CleanupModelSelection.modelID(from: option.id) != nil
    }

    /// The OpenRouter slug a selection is sent as, e.g. "openai/gpt-5-mini".
    public static func modelSlug(for identifier: String) -> String {
        CleanupModelSelection.modelID(from: identifier)
            ?? OpenRouterTranscriptionSelection.modelID(from: identifier)
            ?? identifier
    }

    public static func modelPageURL(for identifier: String) -> URL? {
        let slug = modelSlug(for: identifier)
        let parts = slug.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
              slug.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { return nil }
        return URL(string: "https://openrouter.ai")?.appendingPathComponent(slug)
    }
}

public extension OpenRouterCatalogOptions {
    /// The vendor name for a raw OpenRouter slug, matching bundled options' provider names.
    static func vendorName(forModelSlug slug: String) -> String {
        // Any non-native cleanup slug is OpenRouter-routed, so this resolves the vendor name.
        NativeTextModels.isNative(slug)
            ? String(slug.prefix { $0 != "/" })
            : ModelPickerGrouping.providerName(for: slug, purpose: .postProcessing)
    }
}
