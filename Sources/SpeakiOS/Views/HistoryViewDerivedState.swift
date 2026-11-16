#if os(iOS)
import Foundation
import SpeakCore
import SwiftUI

/// History's view-only search and filter inputs. They narrow what is shown and never change stored entries.
struct HistoryViewFilterKey: Equatable {
    let searchText: String
    let errorsOnly: Bool
    let selectedModel: String?
    let dateRangeEnabled: Bool
    let startDate: Date
    let endDate: Date

    /// Whether a model, error or date filter (not the search text) is narrowing the list.
    var hasActiveFilters: Bool {
        errorsOnly || selectedModel != nil || dateRangeEnabled
    }

    /// The shared query, with dates expanded to whole local days by the shared day policy.
    func query(calendar: Calendar = .current) -> HistorySearchQuery {
        HistorySearchQuery(
            searchText: searchText,
            modelIdentifiers: selectedModel.map { [$0] } ?? [],
            includeErrorsOnly: errorsOnly,
            dateRange: dateRangeEnabled
                ? HistorySearchQuery.normalizedDayRange(from: startDate, through: endDate, calendar: calendar)
                : nil
        )
    }
}

/// Derived rows belong to the view lifecycle and rebuild only from emitted rows or filter changes.
struct HistoryViewDerivedState {
    let filteredItems: [iOSHistoryItem]
    let statistics: HistoryPresentationStatistics
    let availableModels: [String]

    init(items: [iOSHistoryItem], query: HistorySearchQuery) {
        let newItems = items.filter { query.matches($0.presentationItem) }
        filteredItems = newItems
        statistics = HistoryPresentationStatistics(items: newItems.map(\.presentationItem))
        availableModels = Array(Set(items.map(\.model))).sorted {
            ModelCatalog.friendlyName(for: $0) < ModelCatalog.friendlyName(for: $1)
        }
    }
}

/// The last row of a paged History list: shows progress and loads the next
/// page when it scrolls into view. Callers give it an identity that follows the
/// window, so it fires again if it is still on screen after a page loads.
struct HistoryLoadMoreFooter: View {
    let shown: Int
    let total: Int
    let loadMore: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Showing \(shown) of \(total)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("historyLoadMoreFooter")
        .onAppear(perform: loadMore)
    }
}
#endif
