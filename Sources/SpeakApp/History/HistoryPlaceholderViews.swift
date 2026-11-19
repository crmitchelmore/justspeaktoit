import SpeakCore
import SwiftUI

/// Shown while history persistence is degraded (issue #695): the on-disk
/// snapshot is preserved and new sessions stay queued in memory.
struct HistoryPersistenceBanner: View {
  let notice: String
  /// Offers a retry when the history file could not be loaded at all.
  let retry: (() -> Void)?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "externaldrive.badge.exclamationmark")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(self.notice)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      if let retry = self.retry {
        Button("Retry", action: retry)
          .accessibilityLabel("Retry loading history")
      }
    }
    .padding(10)
    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .combine)
  }
}

/// Shown when nothing has been recorded yet.
struct HistoryEmptyState: View {
  let isSessionBusy: Bool
  let startRecording: () -> Void

  @Environment(\.appVisualDensity) private var density

  var body: some View {
    VStack(spacing: self.density.isCompact ? 6 : 18) {
      Image(systemName: "waveform")
        .font(.system(size: self.density.isCompact ? 22 : 44, weight: .medium))
        .foregroundStyle(Color.brandAccent)
      Text("No history yet")
        .font(self.density.isCompact ? .subheadline.bold() : .title2.bold())
      if !self.density.isCompact {
        Text("Record a session to see transcripts, costs, and network activity appear here.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Button(action: self.startRecording) {
        if self.density.isCompact {
          Label("Start a recording", systemImage: "mic.fill")
            .labelStyle(.iconOnly)
        } else {
          Label("Start a recording", systemImage: "mic.fill")
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(self.isSessionBusy)
      .accessibilityIdentifier("historyStartRecordingButton")
    }
    .modifier(HistoryPlaceholderCard())
  }
}

/// Shown when filters are active but nothing matched, so the view never claims
/// the history is empty when it is only filtered down to nothing.
struct HistoryFilteredEmptyState: View {
  let searchText: String
  let clearFilters: () -> Void

  @Environment(\.appVisualDensity) private var density

  var body: some View {
    VStack(spacing: self.density.isCompact ? 6 : 12) {
      if self.searchText.isEmpty {
        ContentUnavailableView(
          "No matching sessions",
          systemImage: "line.3.horizontal.decrease.circle",
          description: Text("No sessions match the current filters. Try widening the date range or clearing them.")
        )
      } else {
        ContentUnavailableView.search(text: self.searchText)
      }

      Button("Clear filters", action: self.clearFilters)
        .buttonStyle(.bordered)
        .accessibilityIdentifier("historyClearFiltersButton")
    }
    .modifier(HistoryPlaceholderCard())
  }
}

/// Placeholder rows shown until history has loaded for the first time.
struct HistorySkeletonList: View {
  @Environment(\.appVisualDensity) private var density

  var body: some View {
    VStack(spacing: self.density.sectionSpacing) {
      HistoryStatsSkeleton()
        .padding(.bottom, self.density.isCompact ? 0 : 8)

      ForEach(0..<3, id: \.self) { _ in
        HistoryItemSkeleton()
          .padding(self.density.isCompact ? 6 : 16)
          .background(
            RoundedRectangle(cornerRadius: self.density.isCompact ? 8 : 20, style: .continuous)
              .fill(.ultraThinMaterial)
          )
          .overlay(
            RoundedRectangle(cornerRadius: self.density.isCompact ? 8 : 20, style: .continuous)
              .stroke(Color.brandAccent.opacity(0.1), lineWidth: 1)
          )
      }
    }
    .frame(maxWidth: .infinity)
  }
}

/// The material card both empty states sit in.
private struct HistoryPlaceholderCard: ViewModifier {
  @Environment(\.appVisualDensity) private var density

  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity)
      .padding(self.density.isCompact ? 12 : 40)
      .background(
        RoundedRectangle(cornerRadius: self.density.cardCornerRadius, style: .continuous)
          .fill(.ultraThinMaterial)
      )
      .overlay(
        RoundedRectangle(cornerRadius: self.density.cardCornerRadius, style: .continuous)
          .stroke(Color.brandAccent.opacity(0.15), lineWidth: 1)
      )
  }
}
