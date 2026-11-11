import SpeakCore
import SwiftUI

/// The History page header: title, search and filters, library actions and
/// summary figures. Compact density gets a single dense strip; otherwise a
/// full-size gradient hero.
struct HistoryHeader: View {
  @ObservedObject var list: HistoryListModel
  @ObservedObject var library: HistoryLibraryActions
  let stats: HistoryStatistics
  /// True while a session is recording or processing, which blocks importing.
  let isSessionBusy: Bool

  @Environment(\.appVisualDensity) private var density
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    if self.density.prefersInlineLayout(dynamicTypeSize: self.dynamicTypeSize) {
      HistoryCompactHeader(list: self.list, library: self.library, stats: self.stats, isSessionBusy: self.isSessionBusy)
    } else {
      HistoryHeroHeader(list: self.list, library: self.library, stats: self.stats, isSessionBusy: self.isSessionBusy)
    }
  }
}

/// The From/To pickers shown while the date-range filter is on.
struct HistoryDateRangePickers: View {
  @ObservedObject var list: HistoryListModel

  var body: some View {
    if self.list.dateRangeEnabled {
      DatePicker("From", selection: self.$list.startDate, displayedComponents: .date)
        .labelsHidden()
        .datePickerStyle(.compact)
      DatePicker("To", selection: self.$list.endDate, in: self.list.startDate..., displayedComponents: .date)
        .labelsHidden()
        .datePickerStyle(.compact)
    }
  }
}

/// Filters history to one transcription or processing model.
struct HistoryModelFilterPicker: View {
  @ObservedObject var list: HistoryListModel

  var body: some View {
    LongListPicker(
      title: "Model",
      items: [LongListChoice<String?>(id: nil, title: "All Models")]
        + self.list.availableModels.map {
          LongListChoice<String?>(id: $0, title: ModelCatalog.friendlyName(for: $0))
        },
      id: { $0.id }, selection: self.$list.selectedModelFilter, searchText: { [$0.title, $0.id ?? ""] },
      menuDividerAfter: { $0.id == nil },
      row: { item in Text(item.title) }
    )
  }
}

/// Formats the header's summary figures.
enum HistoryHeaderFormat {
  private static let currencyFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = 2
    formatter.minimumFractionDigits = 2
    return formatter
  }()

  static func duration(_ duration: TimeInterval) -> String {
    guard duration.isFinite, duration > 0 else { return "—" }
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return String(format: "%02dm %02ds", minutes, seconds)
  }

  static func currency(_ value: Decimal) -> String {
    Self.currencyFormatter.string(from: value as NSDecimalNumber) ?? "—"
  }
}
