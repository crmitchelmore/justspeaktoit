#if os(iOS)
import Foundation
import SpeakCore

struct HistoryViewFilterKey: Equatable {
    let searchText: String
    let errorsOnly: Bool
    let selectedModel: String?
    let dateRangeEnabled: Bool
    let startDate: Date
    let endDate: Date
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
#endif
