import SpeakCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HistoryListRow: View {
  @EnvironmentObject private var environment: AppEnvironment
  @Environment(\.appVisualDensity) private var density
  let item: HistoryItem
  /// Presentation is owned by `HistoryView`: a sheet on a lazy row can present
  /// empty, undismissable content when SwiftUI rebuilds or recycles the row.
  let onReviewIssueReport: (HistoryItem) -> Void
  @State private var isExpanded: Bool = false
  @State private var showNetworkDetails: Bool = false
  @State private var showDeleteConfirmation: Bool = false
  @FocusState private var isFocused: Bool

  var body: some View {
    rowContent
      .focusable()
      .focused($isFocused)
      .focusEffectDisabled()
      .contextMenu {
        HistoryItemContextMenu(
          item: item,
          environment: environment,
          onReviewIssueReport: presentIssueReport,
          onDelete: { showDeleteConfirmation = true }
        )
      }
      .onChange(of: isExpanded) { _, expanded in
        if !expanded {
          showNetworkDetails = false
        }
      }
      .onKeyPress(.delete) {
        showDeleteConfirmation = true
        return .handled
      }
      .onKeyPress(keys: [KeyEquivalent("c")]) { press in
        if press.modifiers == [.command, .shift] {
          if let raw = item.rawTranscription {
            copyToPasteboard(raw)
          }
          return .handled
        } else if press.modifiers == .command {
          if let processed = item.postProcessedTranscription {
            copyToPasteboard(processed)
          } else if let raw = item.rawTranscription {
            copyToPasteboard(raw)
          }
          return .handled
        }
        return .ignored
      }
      .confirmationDialog(
        "Delete History Item",
        isPresented: $showDeleteConfirmation,
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          Task {
            await environment.history.remove(id: item.id)
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Are you sure you want to delete this history item? This action cannot be undone.")
      }
  }
}

private extension HistoryListRow {
  private var rowContent: some View {
    VStack(alignment: .leading, spacing: density.isCompact ? 6 : 20) {
      Button {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
          isExpanded.toggle()
        }
      } label: {
        VStack(alignment: .leading, spacing: density.isCompact ? 4 : 12) {
          HStack(alignment: .top, spacing: density.groupSpacing) {
            ViewThatFits(in: .horizontal) {
              HStack(spacing: density.isCompact ? density.inlineSpacing : 8) {
                HistoryItemBadges(item: item)
              }
              VStack(alignment: .leading, spacing: density.isCompact ? density.inlineSpacing : 8) {
                HistoryItemBadges(item: item)
              }
            }
            Spacer(minLength: 0)
            Button {
              showDeleteConfirmation = true
            } label: {
              Label("Delete", systemImage: "trash")
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .speakTooltip("Delete this history item")
            .accessibilityIdentifier("historyRowDeleteButton-\(item.id)")
            Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
              .imageScale(density.isCompact ? .medium : .large)
              .symbolRenderingMode(.palette)
              .foregroundStyle(Color.brandAccent, Color.brandAccentWarm.opacity(0.35))
          }

          if let transcript = bestTranscript {
            HStack(
              alignment: .firstTextBaseline,
              spacing: density.isCompact ? density.inlineSpacing : 10
            ) {
              Text(previewText)
                .font(density.isCompact ? .caption : .subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(density.isCompact ? 1 : 2)

              CopyButton {
                CopyFeedback.writeToPasteboard(transcript)
              }
              .buttonStyle(.borderless)
              .speakTooltip("Copy the best available transcript")
              .accessibilityIdentifier("historyRowCopyButton-\(item.id)")
            }
          } else {
            Text(previewText)
              .font(density.isCompact ? .caption : .subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(density.isCompact ? 1 : 2)
          }

          if let models = item.modelsSummaryByPhase {
            Label(models, systemImage: "brain.head.profile")
              .font(density.isCompact ? .caption2 : .caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .speakTooltip(
        "Click to open or close full details for this session, including transcripts, costs, and network activity."
      )
      .accessibilityIdentifier("historyRowExpandButton-\(item.id)")

      if isExpanded {
        expandedContent
      }
    }
    .padding(density.cardPadding)
    .background(
      RoundedRectangle(cornerRadius: density.isCompact ? 10 : 32, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: density.isCompact ? 10 : 32, style: .continuous)
        .stroke(borderColor, lineWidth: 1)
    )
    .shadow(
      color: borderColor.opacity(density.isCompact ? 0 : 0.3),
      radius: density.isCompact ? 0 : 18,
      x: 0,
      y: density.isCompact ? 0 : 12
    )
  }

  @ViewBuilder
  private var expandedContent: some View {
    Divider()
      .padding(.vertical, density.isCompact ? 0 : 4)

    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: density.isCompact ? 10 : 28) {
        VStack(alignment: .leading, spacing: density.isCompact ? 8 : 20) {
          if !item.networkExchanges.isEmpty {
            networkSummaryButton
            if showNetworkDetails {
              HistoryItemNetworkSection(item: item)
            }
          }

          HistoryItemPromptDisclosure(item: item)

          HistoryItemMetaSection(item: item)

          if let url = item.audioFileURL {
            AudioPlaybackControls(url: url)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .leading, spacing: density.isCompact ? 8 : 20) {
          transcriptSection

          if !item.errors.isEmpty {
            HistoryItemErrorSection(item: item, onReviewIssueReport: presentIssueReport)
          }

          HistoryItemFooterActions(item: item, onReviewIssueReport: presentIssueReport)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: density.isCompact ? 8 : 20) {
        if !item.networkExchanges.isEmpty {
          networkSummaryButton
          if showNetworkDetails {
            HistoryItemNetworkSection(item: item)
          }
        }

        HistoryItemPromptDisclosure(item: item)

        HistoryItemMetaSection(item: item)

        if let url = item.audioFileURL {
          AudioPlaybackControls(url: url)
        }

        transcriptSection

        if !item.errors.isEmpty {
          HistoryItemErrorSection(item: item, onReviewIssueReport: presentIssueReport)
        }

        HistoryItemFooterActions(item: item, onReviewIssueReport: presentIssueReport)
      }
    }
    .transition(.opacity.combined(with: .move(edge: .top)))
  }

  private var previewText: String {
    if let processed = processedTranscriptToDisplay {
      return processed
    }
    // Same emptiness test as `bestTranscript`, so a whitespace-only transcript
    // can't make the row show blank preview text while the copy button is hidden.
    if let raw = item.rawTranscription,
      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return raw
    }
    return item.trigger.hotKeyDescription
  }

  private var borderColor: Color {
    item.errors.isEmpty ? Color.brandAccent.opacity(0.15) : Color.orange.opacity(0.35)
  }

  private var transcriptSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let processed = processedTranscriptToDisplay {
        Text("Processed Transcript")
          .font(.subheadline.bold())
        transcriptBox(processed)
      }
      if let raw = item.rawTranscription {
        Text("Raw Transcript")
          .font(.subheadline.bold())
        transcriptBox(raw)
      }
    }
  }

  private func transcriptBox(_ text: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(text)
        .font(.body.monospaced())
      CopyButton(presentation: .titleAndIcon) {
        CopyFeedback.writeToPasteboard(text)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
  }

  private var networkSummaryButton: some View {
    let count = item.networkExchanges.count
    let responseSummary: String
    if let last = item.networkExchanges.last {
      responseSummary = "Latest: HTTP \(last.responseCode)"
    } else {
      responseSummary = ""
    }

    return Button {
      withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
        showNetworkDetails.toggle()
      }
    } label: {
      HStack(spacing: 12) {
        Label(
          showNetworkDetails ? "Hide API details" : "Show API details",
          systemImage: showNetworkDetails ? "chevron.up.circle.fill" : "chevron.down.circle"
        )
        .labelStyle(.titleAndIcon)
        .font(.callout.weight(.semibold))

        Spacer(minLength: 8)

        HStack(spacing: 6) {
          Text("\(count) request\(count == 1 ? "" : "s")")
          if !responseSummary.isEmpty {
            Text("•")
            Text(responseSummary)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(Color.brandAccent.opacity(0.09))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(Color.brandAccent.opacity(0.2), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .speakTooltip("Peek behind the scenes to review the API requests and responses that powered this session.")
  }

  private func copyToPasteboard(_ text: String) {
    // Announce here so every path (buttons, context menu, ⌘C) tells VoiceOver
    // the copy happened; `CopyButton` also shows a transient checkmark.
    CopyFeedback.copy(text)
  }

  private func presentIssueReport() {
    onReviewIssueReport(item)
  }

  private var processedTranscriptToDisplay: String? {
    guard
      let processed = item.postProcessedTranscription,
      !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }

    if let raw = item.rawTranscription,
      raw.trimmingCharacters(in: .whitespacesAndNewlines)
        == processed.trimmingCharacters(in: .whitespacesAndNewlines) {
      return nil
    }

    return processed
  }

  private var bestTranscript: String? {
    if let processed = processedTranscriptToDisplay {
      return processed
    }
    if let raw = item.rawTranscription,
      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return raw
    }
    return nil
  }
}
