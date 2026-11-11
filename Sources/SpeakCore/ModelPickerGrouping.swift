import Foundation

/// One shared rule for every model picker: direct routes (native providers and
/// on-device models) are listed first, and OpenRouter is a single entry that
/// opens its own list. Grouping follows the credential each model actually
/// uses, so a picker can never show an OpenRouter route as a native one.
/// Within each group, models are alphabetical by provider, then by model name.
public enum ModelPickerGrouping {
    public static let openRouterTitle = "OpenRouter"
    public static let openRouterSeparator = " › "

    public struct Groups: Equatable, Sendable {
        /// Native-provider and on-device options, by provider then model name.
        public let direct: [ModelCatalog.Option]
        /// OpenRouter options, by vendor then model name, shown only inside the OpenRouter entry.
        public let openRouter: [ModelCatalog.Option]
    }

    public static func groups(_ options: [ModelCatalog.Option], purpose: ModelCredentialPurpose) -> Groups {
        var seen = Set<String>()
        var direct: [ModelCatalog.Option] = []
        var openRouter: [ModelCatalog.Option] = []
        for option in options where option.id != ModelCatalog.customOptionID {
            guard seen.insert(option.id.lowercased()).inserted else { continue }
            if isOpenRouter(option.id, purpose: purpose) {
                openRouter.append(option)
            } else {
                direct.append(option)
            }
        }
        return Groups(
            direct: sortedByProvider(direct, purpose: purpose),
            openRouter: sortedByProvider(openRouter, purpose: purpose)
        )
    }

    /// Alphabetical by provider name, then model name: case-insensitive,
    /// numeric-aware ("GPT-5.4" before "GPT-5.10") and stable for ties.
    public static func sortedByProvider(
        _ options: [ModelCatalog.Option], purpose: ModelCredentialPurpose
    ) -> [ModelCatalog.Option] {
        let keyed = options.enumerated().map { (offset: $0.offset, provider: providerName(for: $0.element.id,
                                                                                       purpose: purpose),
                                               option: $0.element) }
        return keyed.sorted { lhs, rhs in
            if let order = ordered(lhs.provider, rhs.provider) { return order }
            if let order = ordered(lhs.option.displayName, rhs.option.displayName) { return order }
            return lhs.offset < rhs.offset
        }.map(\.option)
    }

    /// The provider a picker sorts and titles a model under. OpenRouter routes use
    /// their vendor ("openai", "anthropic"), not OpenRouter itself.
    public static func providerName(for identifier: String, purpose: ModelCredentialPurpose) -> String {
        if let native = NativeTextModels.route(for: identifier) { return native.provider.displayName }
        let slug = CleanupModelSelection.modelID(from: identifier) ?? identifier
        let prefix = String(slug.prefix { $0 != "/" })
        if !isOpenRouter(identifier, purpose: purpose),
           case .apiKey(_, let providerName) = ModelCredentialResolver.requirement(
               for: identifier, purpose: purpose
           ) {
            return providerName
        }
        return vendorNames[prefix.lowercased()] ?? prefix
    }

    /// Locale-aware, case-insensitive comparison; nil when equal.
    public static func ordered(_ lhs: String, _ rhs: String) -> Bool? {
        switch lhs.compare(rhs, options: [.caseInsensitive, .numeric], range: nil, locale: .current) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return nil
        }
    }

    private static let vendorNames = [
        "anthropic": "Anthropic", "apple": "Apple", "google": "Google", "local": "Local",
        "meta-llama": "Meta Llama", "mistralai": "Mistral", "openai": "OpenAI", "qwen": "Qwen"
    ]

    public static func isOpenRouter(_ identifier: String, purpose: ModelCredentialPurpose) -> Bool {
        guard identifier != ModelCatalog.customOptionID else { return false }
        return ModelCredentialResolver.requirement(for: identifier, purpose: purpose)
            == ModelCredentialResolver.openRouterRequirement
    }

    /// The selected-row label: "OpenRouter › GPT-6 Luna" for an OpenRouter route,
    /// otherwise the model's own name.
    public static func selectionLabel(
        for identifier: String, displayName: String, purpose: ModelCredentialPurpose
    ) -> String {
        isOpenRouter(identifier, purpose: purpose)
            ? openRouterTitle + openRouterSeparator + displayName
            : displayName
    }

    /// One flat list for hosts whose picker cannot nest: direct routes first, then
    /// OpenRouter routes labelled "OpenRouter › Model". Identifiers are unchanged.
    public static func flattened(
        _ options: [ModelCatalog.Option], purpose: ModelCredentialPurpose
    ) -> [ModelCatalog.Option] {
        let groups = groups(options, purpose: purpose)
        return groups.direct + groups.openRouter.map { option in
            ModelCatalog.Option(
                id: option.id,
                displayName: openRouterTitle + openRouterSeparator + option.displayName,
                description: option.description,
                estimatedLatencyMs: option.estimatedLatencyMs,
                latencyTier: option.latencyTier,
                tags: option.tags,
                pricing: option.pricing,
                contextLength: option.contextLength
            )
        }
    }

    /// Case-insensitive search over name, identifier and description.
    public static func filter(_ options: [ModelCatalog.Option], query: String) -> [ModelCatalog.Option] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return options }
        return options.filter {
            $0.displayName.lowercased().contains(trimmed)
                || $0.id.lowercased().contains(trimmed)
                || ($0.description?.lowercased().contains(trimmed) ?? false)
        }
    }
}
