import SpeakCore
import SwiftUI

/// The History header at compact density: one dense strip of search, filters,
/// actions and summary figures.
struct HistoryCompactHeader: View {
  @ObservedObject var list: HistoryListModel
  @ObservedObject var library: HistoryLibraryActions
  let stats: HistoryStatistics
  let isSessionBusy: Bool

  @Environment(\.appVisualDensity) private var density

  var body: some View {
    PageHeroStrip("History", systemImage: "clock.arrow.circlepath", palette: .history) {
      HStack(spacing: 4) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search", text: self.$list.searchText)
          .textFieldStyle(.plain)
          .frame(minWidth: 120, idealWidth: 180, maxWidth: 240)
          .accessibilityIdentifier("historySearchField")
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

      Toggle(isOn: self.$list.showErrorsOnly) {
        Label("Errors only", systemImage: self.list.showErrorsOnly
          ? "exclamationmark.triangle.fill"
          : "exclamationmark.triangle")
          .labelStyle(.iconOnly)
      }
      .toggleStyle(.button)
      .controlSize(.small)
      .speakTooltip("Show sessions with errors")
      .accessibilityIdentifier("historyErrorsOnlyToggle")

      Toggle(isOn: self.$list.dateRangeEnabled) {
        Label("Date range", systemImage: self.list.dateRangeEnabled ? "calendar.badge.checkmark" : "calendar")
          .labelStyle(.iconOnly)
      }
      .toggleStyle(.button)
      .controlSize(.small)
      .speakTooltip("Filter by date range")

      HistoryDateRangePickers(list: self.list)

      if !self.list.availableModels.isEmpty {
        HistoryModelFilterPicker(list: self.list)
          .labelsHidden()
          .pickerStyle(.menu)
          .controlSize(.small)
          .speakTooltip("Filter by model")
      }

      Spacer(minLength: 2)

      if self.library.isImportingFiles {
        ProgressView()
          .controlSize(.mini)
      }

      Button {
        self.library.showImportFiles = true
      } label: {
        Label("Import", systemImage: "square.and.arrow.down")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
      .disabled(self.library.importDisabled(isSessionBusy: self.isSessionBusy))
      .speakTooltip("Import audio")
      .accessibilityLabel("Import audio")
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier("historyImportButton")

      Button {
        self.library.showClearAllConfirmation = true
      } label: {
        Label("Clear All", systemImage: "trash")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
      .disabled(self.library.clearAllDisabled(hasHistory: !self.list.items.isEmpty))
      .speakTooltip("Clear all history")
      .accessibilityLabel("Clear all history")
      .accessibilityHint("Opens a confirmation before deleting all history items")
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier("historyClearAllButton")
    } below: {
      HStack(spacing: self.density.groupSpacing) {
        CompactHeroMetric(title: "Sessions", value: "\(self.stats.totalSessions)", systemImage: "record.circle")
        CompactHeroMetric(
          title: "Errors", value: "\(self.stats.sessionsWithErrors)", systemImage: "exclamationmark.triangle"
        )
        CompactHeroMetric(
          title: "Average", value: HistoryHeaderFormat.duration(self.stats.averageSessionLength), systemImage: "timer"
        )
        CompactHeroMetric(
          title: "Spend", value: HistoryHeaderFormat.currency(self.stats.totalSpend), systemImage: "creditcard"
        )
      }
    }
  }
}
