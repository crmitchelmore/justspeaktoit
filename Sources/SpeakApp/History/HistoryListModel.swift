import Foundation
import SpeakCore

/// Owns the History page's filter inputs and the filtered, paged list they
/// produce. Filtering is cached here so a body pass doesn't re-filter the full
/// history several times per render; it is recomputed only when the source
/// items or a filter input change.
@MainActor
final class HistoryListModel: ObservableObject {
  @Published var searchText: String = "" {
    didSet { if oldValue != self.searchText { self.filtersChanged() } }
  }
  @Published var showErrorsOnly: Bool = false {
    didSet { if oldValue != self.showErrorsOnly { self.filtersChanged() } }
  }
  @Published var dateRangeEnabled: Bool = false {
    didSet { if oldValue != self.dateRangeEnabled { self.filtersChanged() } }
  }
  @Published var startDate: Date {
    didSet { if oldValue != self.startDate { self.filtersChanged() } }
  }
  @Published var endDate: Date {
    didSet { if oldValue != self.endDate { self.filtersChanged() } }
  }
  @Published var selectedModelFilter: String? {
    didSet { if oldValue != self.selectedModelFilter { self.filtersChanged() } }
  }

  @Published private(set) var items: [HistoryItem] = []
  @Published private(set) var filteredItems: [HistoryItem] = []
  /// Every model used across `items`, cached so the picker doesn't recompute
  /// it on every render.
  @Published private(set) var availableModels: [String] = []
  /// Rows are built a page at a time; filtering still covers all history.
  @Published private(set) var pageWindow = HistoryPageWindow()

  init(now: Date = Date(), calendar: Calendar = .current) {
    self.startDate = calendar.startOfDay(for: now.addingTimeInterval(-7 * 24 * 60 * 60))
    self.endDate = now
  }

  var displayedItems: ArraySlice<HistoryItem> {
    self.filteredItems.prefix(self.pageWindow.visibleCount(of: self.filteredItems.count))
  }

  var hasMore: Bool { self.pageWindow.hasMore(total: self.filteredItems.count) }

  /// True when any search text, toggle, or picker is narrowing the list, so an
  /// empty result means "nothing matched" rather than "nothing recorded yet".
  var isFilterActive: Bool {
    !self.searchText.isEmpty || self.showErrorsOnly || self.dateRangeEnabled || self.selectedModelFilter != nil
  }

  /// Replaces the source items, keeping the current filters and page.
  func show(_ items: [HistoryItem]) {
    self.items = items
    self.recomputeFilteredItems()
    let unique = Set(items.flatMap(\.modelsUsed))
    self.availableModels = unique.sorted { ModelCatalog.friendlyName(for: $0) < ModelCatalog.friendlyName(for: $1) }
  }

  func loadMore() {
    self.pageWindow.loadMore(total: self.filteredItems.count)
  }

  func clearFilters() {
    self.searchText = ""
    self.showErrorsOnly = false
    self.dateRangeEnabled = false
    self.selectedModelFilter = nil
    self.filtersChanged()
  }

  /// A new search or filter starts again from the first page of its matches.
  private func filtersChanged() {
    self.pageWindow.reset()
    self.recomputeFilteredItems()
  }

  private func recomputeFilteredItems() {
    var filter = HistoryFilter.none
    filter.searchText = self.searchText.isEmpty ? nil : self.searchText
    filter.includeErrorsOnly = self.showErrorsOnly
    if let model = self.selectedModelFilter {
      filter.modelIdentifiers = [model]
    }
    if self.dateRangeEnabled {
      filter.dateRange = HistorySearchQuery.normalizedDayRange(from: self.startDate, through: self.endDate)
    }
    self.filteredItems = self.items.filter { filter.matches($0.presentationItem) }
  }
}
