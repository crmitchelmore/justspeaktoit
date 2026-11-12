import SwiftUI

/// What a discovery browser shows above its list: refresh progress, errors and freshness.
struct OpenRouterBrowserStatus: Equatable {
    var isRefreshing = false
    var errorMessage: String?
    var lastUpdated: Date?
    var isStale = false
    /// A saved selection the current catalogue no longer lists; it is retained, not replaced.
    var missingSelection: String?
}

/// The discover-then-configure flow every OpenRouter picker shares: a refreshable,
/// searchable list filtered by provider and listed price, where each model opens a
/// detail page that configures and confirms the choice. Speech, transcription and
/// cleanup supply only their models, header controls and detail page.
@MainActor
struct OpenRouterModelBrowser<Item: Identifiable, Header: View, Detail: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let intro: String
    /// Models in display order; the browser only filters them.
    let items: [Item]
    let status: OpenRouterBrowserStatus
    let canRefresh: Bool
    /// Pushed inside an existing navigation stack, so it adds neither a stack nor a Done button.
    let embedded: Bool
    let searchText: (Item) -> [String]
    let provider: (Item) -> String
    let hasZeroPrices: (Item) -> Bool
    let name: (Item) -> String
    let subtitle: (Item) -> String
    let isSelected: (Item) -> Bool
    let refresh: (_ force: Bool) async -> Void
    /// Returns to the caller's own list (for example native providers) instead of closing.
    let onBack: (() -> Void)?
    @ViewBuilder let header: () -> Header
    @ViewBuilder let detail: (Item) -> Detail

    @State private var filter = OpenRouterBrowserFilter()

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack {
                content.toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("openRouterBrowser.done")
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 560, idealWidth: 720, minHeight: 500, idealHeight: 680)
            #endif
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            controls.padding()
            List {
                statusRows
                ForEach(filtered) { item in
                    NavigationLink {
                        detail(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name(item)).font(.headline)
                            Text(subtitle(item)).font(.caption).foregroundStyle(.secondary)
                            if isSelected(item) {
                                Label("Selected", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            if let onBack {
                ToolbarItem(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left", action: onBack)
                        .accessibilityIdentifier("openRouterBrowser.back")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refresh(true) }
                }
                .disabled(!canRefresh || status.isRefreshing)
                .accessibilityIdentifier("openRouterBrowser.refresh")
            }
        }
        .task { await refresh(false) }
    }

    private var filtered: [Item] {
        items.filter { item in
            filter.matches(searchText: searchText(item), provider: provider(item), hasZeroPrices: hasZeroPrices(item))
        }
    }

    private var providers: [String] {
        Array(Set(items.map(provider))).sorted()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(intro).font(.caption).foregroundStyle(.secondary)
            header()
            TextField("Search models", text: $filter.query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("openRouterBrowser.search")
            HStack {
                Picker("Provider", selection: $filter.provider) {
                    Text("All providers").tag("")
                    ForEach(providers, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Zero listed prices", isOn: $filter.freeOnly)
            }
        }
    }

    @ViewBuilder
    private var statusRows: some View {
        if status.isRefreshing { ProgressView("Refreshing models…") }
        if let error = status.errorMessage { Text(error).foregroundStyle(.orange) }
        if let updated = status.lastUpdated {
            Text("\(status.isStale ? "Cached, refresh needed" : "Updated"): \(updated.formatted())")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let missing = status.missingSelection {
            Label("Selected model is unavailable in this catalogue: \(missing). Your selection is retained.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        if !status.isRefreshing, filtered.isEmpty {
            Text("No matching models. Change the filters or refresh the catalogue.")
                .foregroundStyle(.secondary)
        }
    }
}
