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
    VStack(alignment: .leading, spacing: 18) {
      // The actions sit beside the title so the filter row keeps enough room
      // for its labels instead of wrapping or truncating them.
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Session History")
            .font(.largeTitle.bold())
            .foregroundStyle(.white)
          Text(
            "Search, filter, and replay past recordings with full network context and transcripts."
          )
          .font(.headline)
          .foregroundStyle(.white.opacity(0.85))
        }

        Spacer(minLength: 0)

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

      self.normalFilterRow

      HStack(spacing: 16) {
        self.historyChip(title: "Sessions", value: "\(self.stats.totalSessions)")
        self.historyChip(title: "Errors", value: "\(self.stats.sessionsWithErrors)")
        self.historyChip(title: "Average Length", value: HistoryHeaderFormat.duration(self.stats.averageSessionLength))
        self.historyChip(title: "Spend", value: HistoryHeaderFormat.currency(self.stats.totalSpend))
      }
    }
    .padding(24)
    .background(
      LinearGradient(
        colors: [Color.brandAccentDeep, Color.brandAccentWarm.opacity(0.9)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .cornerRadius(32)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 32, style: .continuous)
        .stroke(Color.white.opacity(0.15), lineWidth: 1)
    )
    .shadow(color: Color.brandAccent.opacity(0.3), radius: 24, x: 0, y: 16)
  }

  private var normalFilterRow: some View {
    HStack(spacing: 16) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.white.opacity(0.7))
        TextField("Search history", text: self.$list.searchText)
          .textFieldStyle(.plain)
          .foregroundColor(.white)
          .speakTooltip(
            "Search your past sessions by transcript, model, or keyword so you can quickly revisit the right moment."
          )
          .accessibilityIdentifier("historySearchField")
      }
      .padding(.vertical, 12)
      .padding(.horizontal, 16)
      .background(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(Color.white.opacity(0.14))
      )

      Toggle("Errors only", isOn: self.$list.showErrorsOnly)
        .toggleStyle(.switch)
        .fixedSize()
        .tint(.brandAccentWarm)
        .foregroundStyle(.white)
        .speakTooltip("Show only sessions where Speak spotted issues, making it easy to focus on what needs attention.")
        .accessibilityIdentifier("historyErrorsOnlyToggle")

      Toggle("Date range", isOn: self.$list.dateRangeEnabled)
        .toggleStyle(.switch)
        .fixedSize()
        .tint(.brandAccentWarm)
        .foregroundStyle(.white)
        .speakTooltip("Filter sessions to a specific date range.")

      HistoryDateRangePickers(list: self.list)

      if !self.list.availableModels.isEmpty {
        HistoryModelFilterPicker(list: self.list)
          .pickerStyle(.menu)
          .fixedSize()
          .tint(.white)
          .foregroundStyle(.white)
          .speakTooltip("Filter sessions by the transcription or processing model used.")
      }
    }
  }

  private func historyChip(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title.uppercased())
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.7))
      Text(value)
        .font(.headline)
        .foregroundStyle(.white)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(Color.white.opacity(0.15))
    )
  }
}
