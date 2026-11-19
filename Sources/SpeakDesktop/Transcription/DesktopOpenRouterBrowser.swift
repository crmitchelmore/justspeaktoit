import Foundation
import SpeakCore

/// The Windows and Linux **Browse OpenRouter models…** browser (#1618): the shared
/// `OpenRouterModelBrowserCatalog` items, each bound to the native picker slot that
/// choosing it selects. Native dialogs only render a `Page`; search, provider and
/// zero-price filtering, row text and details copy are defined here once.
package struct DesktopOpenRouterBrowser: Equatable, Sendable {
    package struct Row: Equatable, Sendable {
        package let item: OpenRouterBrowserItem
        /// The native picker slot that choosing this model selects.
        package let slot: Int32
        package let selected: Bool
        package let details: String
        package let automationID: String

        package var title: String { item.name }
        package var subtitle: String { item.subtitle }
        package var url: String { item.modelPageURL?.absoluteString ?? "" }
    }

    package struct Page: Equatable, Sendable {
        package let title: String
        package let intro: String
        package let action: String
        package let selectedAction: String
        package let status: String
        package let providers: [String]
        package let rows: [Row]
    }

    package static let detailsLinkTitle = "Model details on OpenRouter"
    package static let listedPricesNote =
        "These are the provider's listed values. Units vary by model; check OpenRouter before use."

    package let purpose: OpenRouterModelBrowserCatalog.Purpose
    /// Only items the native picker can select; the order is the shared catalogue's.
    package let items: [OpenRouterBrowserItem]
    private let slots: [String: Int32]

    package init(
        purpose: OpenRouterModelBrowserCatalog.Purpose, items: [OpenRouterBrowserItem], slots: [String: Int32]
    ) {
        self.purpose = purpose
        self.items = items.filter { slots[$0.id] != nil }
        self.slots = slots
    }

    package var providers: [String] { OpenRouterModelBrowserCatalog.providers(in: items) }

    package func slot(for identifier: String) -> Int32? { slots[identifier] }

    /// `selectedSlot` is the picker's current choice, so the flag follows unsaved edits.
    package func page(matching filter: OpenRouterBrowserFilter, selectedSlot: Int32) -> Page {
        let shown = OpenRouterModelBrowserCatalog.filtered(items, by: filter)
        let rows = shown.compactMap { item -> Row? in
            guard let slot = slots[item.id] else { return nil }
            return Row(
                item: item, slot: slot, selected: slot == selectedSlot,
                details: Self.details(for: item, purpose: purpose),
                automationID: Self.automationID(for: item.id, purpose: purpose)
            )
        }
        return Page(
            title: OpenRouterModelBrowserCatalog.title(for: purpose),
            intro: OpenRouterModelBrowserCatalog.intro(for: purpose),
            action: OpenRouterModelBrowserCatalog.actionTitle(for: purpose, selected: false),
            selectedAction: OpenRouterModelBrowserCatalog.actionTitle(for: purpose, selected: true),
            status: rows.isEmpty ? OpenRouterModelBrowserCatalog.emptyResults
                : "\(rows.count) of \(items.count) models",
            providers: providers, rows: rows
        )
    }

    /// The details pane: model, provider, context, pricing, then the route note.
    package static func details(
        for item: OpenRouterBrowserItem, purpose: OpenRouterModelBrowserCatalog.Purpose
    ) -> String {
        var lines = [item.name, item.slug]
        let summary = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { lines.append(summary) }
        lines.append("Provider: \(item.provider)")
        if let length = item.contextLength { lines.append("Context limit: \(length) tokens") }
        if item.isUnqualifiedDiscovery { lines.append(OpenRouterModelBrowserCatalog.unqualifiedWarning) }
        if let pricing = item.pricing {
            lines.append("Input / output: \(pricing.displayName) tokens")
            lines.append(OpenRouterModelBrowserCatalog.pricingCaveat)
        } else if !item.listedPrices.isEmpty {
            lines += item.listedPrices.keys.sorted().map { "\($0): \(item.listedPrices[$0] ?? "")" }
            lines.append(listedPricesNote)
        } else {
            lines.append(OpenRouterModelBrowserCatalog.pricingUnlisted)
        }
        lines.append(OpenRouterModelBrowserCatalog.routeNote(for: purpose))
        return lines.joined(separator: "\n")
    }

    /// A stable handle for UI automation, e.g. `openRouterBrowser.cleanup.openai-gpt-5-mini`.
    package static func automationID(
        for identifier: String, purpose: OpenRouterModelBrowserCatalog.Purpose
    ) -> String {
        let slug = OpenRouterCatalogOptions.modelSlug(for: identifier).lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-"
        }
        return "openRouterBrowser.\(purpose.rawValue).\(String(slug))"
    }
}

extension DesktopOpenRouterBrowser {
    /// The cleanup browser over a published post-processing list: `remote` is the raw
    /// (unprefixed) remote options and `published` the list whose indices are the slots.
    package static func cleanup(
        remote: [ModelCatalog.Option], published: [ModelCatalog.Option]
    ) -> DesktopOpenRouterBrowser {
        DesktopOpenRouterBrowser(
            purpose: .cleanup, items: OpenRouterModelBrowserCatalog.cleanupItems(options: remote),
            slots: slotMap(published.map(\.id))
        )
    }

    /// The batch transcription browser over the host's model slots. Only visible
    /// remote batch slots can be chosen; live and on-device slots are never offered.
    package static func transcription(
        discovered: [OpenRouterAudioModel], slots state: DesktopModelSlots
    ) -> DesktopOpenRouterBrowser {
        var slots: [String: Int32] = [:]
        for index in state.visibleIndices where !state.entries[index].isLive && !state.entries[index].isLocal {
            slots[state.entries[index].option.id] = slots[state.entries[index].option.id] ?? Int32(index)
        }
        return DesktopOpenRouterBrowser(
            purpose: .transcription,
            items: OpenRouterModelBrowserCatalog.transcriptionItems(
                bundled: DesktopTranscription.batchModels, discovered: discovered
            ),
            slots: slots
        )
    }

    private static func slotMap(_ identifiers: [String]) -> [String: Int32] {
        var slots: [String: Int32] = [:]
        for (index, identifier) in identifiers.enumerated() where slots[identifier] == nil {
            slots[identifier] = Int32(index)
        }
        return slots
    }
}
