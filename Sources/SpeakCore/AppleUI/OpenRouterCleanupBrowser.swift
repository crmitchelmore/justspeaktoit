import SwiftUI

/// The OpenRouter level of the cleanup model picker, in the same discover-then-configure
/// flow as OpenRouter speech and transcription: bundled models plus opt-in discovery,
/// each opening a detail page that shows its pricing and settings before it is chosen.
@MainActor
public struct OpenRouterCleanupBrowser: View {
    @Environment(\.dismiss) private var dismiss
    @Binding private var discoveryEnabled: Bool
    @State private var state = CleanupModelDiscoveryStore.shared.snapshot
    @State private var refreshing = false
    private let selection: String
    private let options: () -> [ModelCatalog.Option]
    private let temperature: Binding<Double>?
    private let embedded: Bool
    private let onBack: (() -> Void)?
    private let onSelect: (String) -> Void

    /// - Parameters:
    ///   - options: Every cleanup option the host offers; only OpenRouter routes are listed.
    ///     Re-read after each discovery refresh.
    ///   - temperature: The shared remote cleanup temperature, configured on each model's page.
    public init(
        selection: String,
        discoveryEnabled: Binding<Bool>,
        options: @escaping () -> [ModelCatalog.Option] = {
            CleanupModelDiscoveryStore.shared.options(selected: nil)
        },
        temperature: Binding<Double>? = nil,
        embedded: Bool = false,
        onBack: (() -> Void)? = nil,
        onSelect: @escaping (String) -> Void
    ) {
        self.selection = selection
        _discoveryEnabled = discoveryEnabled
        self.options = options
        self.temperature = temperature
        self.embedded = embedded
        self.onBack = onBack
        self.onSelect = onSelect
    }

    public var body: some View {
        OpenRouterModelBrowser(
            title: OpenRouterModelBrowserCatalog.title(for: .cleanup),
            intro: OpenRouterModelBrowserCatalog.intro(for: .cleanup),
            items: OpenRouterCatalogOptions.models(from: options(), purpose: .postProcessing),
            status: status,
            canRefresh: discoveryEnabled,
            embedded: embedded,
            searchText: { OpenRouterCatalogOptions.searchText(for: $0, purpose: .postProcessing) },
            provider: { OpenRouterCatalogOptions.provider(for: $0, purpose: .postProcessing) },
            hasZeroPrices: OpenRouterCatalogOptions.hasZeroPrices,
            name: \.displayName,
            subtitle: { option in
                [OpenRouterCatalogOptions.modelSlug(for: option.id), option.pricing?.displayName]
                    .compactMap { $0 }.joined(separator: " · ")
            },
            isSelected: { $0.id.caseInsensitiveCompare(selection) == .orderedSame },
            refresh: { await refresh(force: $0) },
            onBack: onBack,
            header: { discoveryControls },
            detail: { option in
                OpenRouterOptionDetail(
                    option: option,
                    purpose: .postProcessing,
                    actionTitle: OpenRouterModelBrowserCatalog.actionTitle(for: .cleanup, selected: false),
                    selectedTitle: OpenRouterModelBrowserCatalog.actionTitle(for: .cleanup, selected: true),
                    routeNote: OpenRouterModelBrowserCatalog.routeNote(for: .cleanup),
                    isSelected: option.id.caseInsensitiveCompare(selection) == .orderedSame,
                    temperature: temperature
                ) { identifier in
                    onSelect(identifier)
                    dismiss()
                }
            }
        )
        .task(id: discoveryEnabled) {
            CleanupModelDiscoveryStore.shared.setEnabled(discoveryEnabled)
            state = CleanupModelDiscoveryStore.shared.snapshot
            if discoveryEnabled { await refresh(force: false) }
        }
    }

    private var status: OpenRouterBrowserStatus {
        let updated = discoveryEnabled ? state.lastUpdated : nil
        return OpenRouterBrowserStatus(
            isRefreshing: refreshing,
            errorMessage: discoveryEnabled ? state.errorMessage : nil,
            lastUpdated: updated,
            isStale: updated.map { Date().timeIntervalSince($0) > CleanupModelDiscoveryStore.cacheLifetime } ?? false
        )
    }

    private var discoveryControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(CleanupModelSelection.settingTitle, isOn: $discoveryEnabled)
                .accessibilityIdentifier("openRouterCleanup.discovery")
            Text(OpenRouterModelBrowserCatalog.discoveryNote)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refresh(force: Bool) async {
        guard discoveryEnabled, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        state = await CleanupModelDiscoveryStore.shared.refresh(force: force)
    }
}
