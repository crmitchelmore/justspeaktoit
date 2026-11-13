import SpeakCore
import SwiftUI

/// The full-size History header: a gradient hero with title, actions, filters
/// and summary chips.
struct HistoryHeroHeader: View {
  @ObservedObject var list: HistoryListModel
  @ObservedObject var library: HistoryLibraryActions
  let stats: HistoryStatistics
  let isSessionBusy: Bool

  var body: some View {
    // The actions sit beside the title so the filter row keeps enough room
    // for its labels instead of wrapping or truncating them.
    PageHeroHeader(
      "Session History",
      subtitle: "Search, filter, and replay past recordings with full network context and transcripts.",
      palette: .history
    ) {
      HStack(alignment: .top, spacing: 16) {
        if self.library.isImportingFiles {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          self.library.showImportFiles = true
        } label: {
          Label("Import…", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        .tint(.brandAccentWarm)
        .foregroundStyle(Color.brandAccentDeep)
        .disabled(self.library.importDisabled(isSessionBusy: self.isSessionBusy))
        .speakTooltip("Import existing audio files into history and transcribe them with your current settings.")
        .accessibilityIdentifier("historyImportButton")

        Button {
          self.library.showClearAllConfirmation = true
        } label: {
          Label("Clear All", systemImage: "trash")
        }
        .buttonStyle(.borderedProminent)
        .tint(.brandAccentWarm)
        .foregroundStyle(Color.brandAccentDeep)
        .disabled(self.library.clearAllDisabled(hasHistory: !self.list.items.isEmpty))
        .speakTooltip("Clear every saved session entry from this history view.")
        .accessibilityIdentifier("historyClearAllButton")
      }
    } content: {
      self.normalFilterRow

      HStack(spacing: 16) {
        HeroStatChip(title: "Sessions", value: "\(self.stats.totalSessions)", systemImage: "record.circle")
        HeroStatChip(
          title: "Errors", value: "\(self.stats.sessionsWithErrors)", systemImage: "exclamationmark.triangle"
        )
        HeroStatChip(
          title: "Average Length",
          value: HistoryHeaderFormat.duration(self.stats.averageSessionLength),
          systemImage: "timer"
        )
        HeroStatChip(
          title: "Spend", value: HistoryHeaderFormat.currency(self.stats.totalSpend), systemImage: "creditcard"
        )
      }
    }
  }

  private var normalFilterRow: some View {
    HStack(spacing: 16) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(SpeakTextStyle.onTintSecondary)
        TextField("Search history", text: self.$list.searchText)
          .textFieldStyle(.plain)
          .speakTooltip(
            "Search your past sessions by transcript, model, or keyword so you can quickly revisit the right moment."
          )
          .accessibilityIdentifier("historySearchField")
      }
      .padding(.vertical, 12)
      .padding(.horizontal, 16)
      .background(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(SpeakTextStyle.onTintFill)
      )

      Toggle("Errors only", isOn: self.$list.showErrorsOnly)
        .toggleStyle(.switch)
        .fixedSize()
        .tint(.brandAccentWarm)
        .speakTooltip("Show only sessions where Speak spotted issues, making it easy to focus on what needs attention.")
        .accessibilityIdentifier("historyErrorsOnlyToggle")

      Toggle("Date range", isOn: self.$list.dateRangeEnabled)
        .toggleStyle(.switch)
        .fixedSize()
        .tint(.brandAccentWarm)
        .speakTooltip("Filter sessions to a specific date range.")

      HistoryDateRangePickers(list: self.list)

      if !self.list.availableModels.isEmpty {
        HistoryModelFilterPicker(list: self.list)
          .pickerStyle(.menu)
          .fixedSize()
          .tint(SpeakTextStyle.onTint)
          .speakTooltip("Filter sessions by the transcription or processing model used.")
      }
    }
  }
}
