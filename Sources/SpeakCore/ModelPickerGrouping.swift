import Foundation

/// One shared rule for every model picker: direct routes (native providers and
/// on-device models) are listed first, and OpenRouter is a single entry that
/// opens its own list. Grouping follows the credential each model actually
/// uses, so a picker can never show an OpenRouter route as a native one.
public enum ModelPickerGrouping {
    public static let openRouterTitle = "OpenRouter"
    public static let openRouterSeparator = " › "

    public struct Groups: Equatable, Sendable {
        /// Native-provider and on-device options, in catalogue order.
        public let direct: [ModelCatalog.Option]
        /// Options served through OpenRouter, shown only inside the OpenRouter entry.
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
        return Groups(direct: direct, openRouter: openRouter)
    }

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
