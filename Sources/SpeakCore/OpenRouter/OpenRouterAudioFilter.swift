import Foundation

/// Search metadata without interpreting provider-specific price units.
struct OpenRouterAudioFilter {
    var capability: OpenRouterAudioCapability = .transcription
    var query = ""
    var provider = ""
    var freeOnly = false

    func matches(_ model: OpenRouterAudioModel) -> Bool {
        guard model.supports(capability) else { return false }
        if !provider.isEmpty, Self.provider(for: model) != provider { return false }
        if freeOnly, !Self.hasZeroPrices(model) { return false }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty || [model.id, model.name, model.description].contains {
            $0.localizedCaseInsensitiveContains(search)
        }
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
