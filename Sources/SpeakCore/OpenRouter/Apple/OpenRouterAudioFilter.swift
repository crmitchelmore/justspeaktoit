import Foundation

/// Search, provider and listed-price filtering shared by every OpenRouter browser.
struct OpenRouterBrowserFilter: Equatable {
    var query = ""
    var provider = ""
    var freeOnly = false

    func matches(searchText: [String], provider itemProvider: String, hasZeroPrices: Bool) -> Bool {
        if !provider.isEmpty, itemProvider != provider { return false }
        if freeOnly, !hasZeroPrices { return false }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty || searchText.contains { $0.localizedCaseInsensitiveContains(search) }
    }
}

/// Search metadata without interpreting provider-specific price units.
struct OpenRouterAudioFilter {
    var capability: OpenRouterAudioCapability = .transcription
    var query = ""
    var provider = ""
    var freeOnly = false

    func matches(_ model: OpenRouterAudioModel) -> Bool {
        guard model.supports(capability) else { return false }
        return OpenRouterBrowserFilter(query: query, provider: provider, freeOnly: freeOnly).matches(
            searchText: Self.searchText(for: model),
            provider: Self.provider(for: model),
            hasZeroPrices: Self.hasZeroPrices(model)
        )
    }

    static func searchText(for model: OpenRouterAudioModel) -> [String] {
        [model.id, model.name, model.description]
    }

    static func provider(for model: OpenRouterAudioModel) -> String {
        String(model.id.split(separator: "/").first ?? Substring(model.id))
    }

    static func hasZeroPrices(_ model: OpenRouterAudioModel) -> Bool {
        !model.pricing.isEmpty && model.pricing.values.allSatisfy { value in
            let pattern = #"^[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#
            guard let match = value.range(of: pattern, options: .regularExpression),
                  match.lowerBound == value.startIndex, match.upperBound == value.endIndex else { return false }
            return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) == .zero
        }
    }
}
