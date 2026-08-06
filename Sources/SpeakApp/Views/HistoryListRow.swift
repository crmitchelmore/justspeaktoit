// swiftlint:disable file_length
import SpeakCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HistoryListRow: View { // swiftlint:disable:this type_body_length
  @EnvironmentObject private var environment: AppEnvironment
  @Environment(\.appVisualDensity) private var density
  let item: HistoryItem
  @State private var isExpanded: Bool = false
  @State private var showNetworkDetails: Bool = false
  @State private var showDeleteConfirmation: Bool = false
  @FocusState private var isFocused: Bool

  var body: some View {
    rowContent
      .focusable()
      .focused($isFocused)
      .focusEffectDisabled()
      .contextMenu { contextMenuContent }
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
                badgeViews
              }
              VStack(alignment: .leading, spacing: density.isCompact ? density.inlineSpacing : 8) {
                badgeViews
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
            .accessibilityIdentifier("historyRowDeleteButton")
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

              Button {
                copyToPasteboard(transcript)
              } label: {
                Label("Copy", systemImage: "doc.on.doc")
                  .labelStyle(.iconOnly)
              }
              .buttonStyle(.borderless)
              .speakTooltip("Copy the best available transcript")
              .accessibilityIdentifier("historyRowCopyButton")
            }
          } else {
            Text(previewText)
              .font(density.isCompact ? .caption : .subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(density.isCompact ? 1 : 2)
          }

          if let models = modelsSummaryByPhase {
            Label(models, systemImage: "brain.head.profile")
              .font(density.isCompact ? .caption2 : .caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .speakTooltip("Click to open or close full details for this session, including transcripts, costs, and network activity.")
      .accessibilityIdentifier("historyRowExpandButton")

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
              networkSection
            }
          }

          promptDisclosureSection

          metaSection

          if let url = item.audioFileURL {
            AudioPlaybackControls(url: url)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .leading, spacing: density.isCompact ? 8 : 20) {
          transcriptSection

          if !item.errors.isEmpty {
            errorSection
          }

          footerActions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: density.isCompact ? 8 : 20) {
        if !item.networkExchanges.isEmpty {
          networkSummaryButton
          if showNetworkDetails {
            networkSection
          }
        }

        promptDisclosureSection

        metaSection

        if let url = item.audioFileURL {
          AudioPlaybackControls(url: url)
        }

        transcriptSection

        if !item.errors.isEmpty {
          errorSection
        }

        footerActions
      }
    }
    .transition(.opacity.combined(with: .move(edge: .top)))
  }

  @ViewBuilder
  private var contextMenuContent: some View {
    if let raw = item.rawTranscription {
      Button {
        copyToPasteboard(raw)
      } label: {
        Label("Copy Raw Transcription", systemImage: "doc.on.doc")
      }
    }

    if let processed = item.postProcessedTranscription {
      Button {
        copyToPasteboard(processed)
      } label: {
        Label("Copy Processed Transcription", systemImage: "doc.on.doc.fill")
      }
    }

    if !item.errors.isEmpty {
      Divider()

      Button {
        openGitHubIssue()
      } label: {
        Label("Open GitHub Issue", systemImage: "ladybug")
      }

      Button {
        copyIssueReport()
      } label: {
        Label("Copy Issue Report", systemImage: "doc.on.clipboard")
      }
    }

    Divider()

    if item.audioFileURL != nil {
      Button {
        Task { await environment.main.reprocessHistoryItem(item) }
      } label: {
        Label("Reprocess with Current Model", systemImage: "arrow.triangle.2.circlepath")
      }
      .disabled(environment.main.isBusy)
      .speakTooltip(reprocessTooltip)
    }

    if let url = item.audioFileURL {
      Button {
        NSWorkspace.shared.open(url)
      } label: {
        Label("Play Audio", systemImage: "play.circle")
      }

      Button {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      } label: {
        Label("Show in Finder", systemImage: "folder")
      }
    }

    Divider()

    Button(role: .destructive) {
      showDeleteConfirmation = true
    } label: {
      Label("Delete", systemImage: "trash")
    }
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

  private var metaColumns: [GridItem] {
    [
      GridItem(
        .adaptive(
          minimum: density.isCompact ? 120 : 160,
          maximum: density.isCompact ? 240 : 340
        ),
        spacing: density.isCompact ? density.inlineSpacing : 10,
        alignment: .topLeading
      )
    ]
  }

  private var formattedCreatedAt: String {
    item.createdAt.formatted(date: .abbreviated, time: .shortened)
  }

  @ViewBuilder
  private var badgeViews: some View {
    historyBadge(
      icon: "calendar",
      title: "Created",
      value: formattedCreatedAt
    )

    if item.source == .importedFile {
      historyBadge(
        icon: "tray.and.arrow.down",
        title: "Source",
        value: "Imported",
        tint: .brandLagoon
      )
    }

    if item.recordingDuration > 0 {
      historyBadge(
        icon: "waveform",
        title: "Audio",
        value: formatDuration(item.recordingDuration)
      )
    }

    if let prompt = promptDuration {
      historyBadge(
        icon: "bolt.fill",
        title: "Prompt",
        value: formatDuration(prompt),
        tint: .brandAccent
      )
    }

    if let cost = item.cost {
      historyBadge(
        icon: "creditcard",
        title: "Cost",
        value: formatCurrency(cost.total, currency: cost.currency),
        tint: .green
      )
    }

    if let error = errorBadgeInfo {
      historyBadge(
        icon: "exclamationmark.triangle.fill",
        title: error.title,
        value: error.value,
        tint: .orange
      )
    }
  }

  private func historyBadge(
    icon: String,
    title: String,
    value: String,
    tint: Color = .accentColor
  ) -> some View {
    Group {
      if density.isCompact {
        HStack(spacing: 3) {
          Image(systemName: icon)
            .imageScale(.small)
          Text(value)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
      } else {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Image(systemName: icon)
              .imageScale(.medium)
            Text(title.uppercased())
              .font(.caption2.weight(.semibold))
          }
          .foregroundStyle(tint)

          Text(value)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint.opacity(0.12))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(tint.opacity(0.2), lineWidth: 1)
        )
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title): \(value)")
  }
  private var promptDuration: TimeInterval? {
    let start =
      item.phaseTimestamps.transcriptionStarted
      ?? item.phaseTimestamps.recordingEnded
      ?? item.phaseTimestamps.recordingStarted
    let end =
      item.phaseTimestamps.outputDelivered
      ?? item.phaseTimestamps.postProcessingEnded
      ?? item.phaseTimestamps.transcriptionEnded

    guard let start, let end else { return nil }

    let duration = end.timeIntervalSince(start)
    guard duration.isFinite, duration > 0 else { return nil }

    return duration
  }

  private var errorBadgeInfo: (title: String, value: String)? {
    guard !item.errors.isEmpty else { return nil }
    if item.errors.count == 1 {
      let phase = item.errors.first?.phase.rawValue.capitalized ?? "Issue"
      return (title: "Error", value: phase)
    }
    return (title: "Errors", value: "\(item.errors.count) issues")
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

  private var metaSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Session Details")
        .font(.subheadline.bold())

      LazyVGrid(columns: metaColumns, alignment: .leading, spacing: 12) {
        metaTile(icon: "bolt.horizontal.circle", title: "Trigger") {
          VStack(alignment: .leading, spacing: 2) {
            Text(item.trigger.gesture.rawValue.capitalized)
            Text("Hotkey: \(item.trigger.hotKeyDescription)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if let destination = item.trigger.destinationApplication {
          metaTile(icon: "app", title: "Destination") {
            Text(destination)
          }
        }

        if !item.modelUsages.isEmpty {
          metaTile(icon: "brain.head.profile", title: "Models") {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(groupedModelsByPhase, id: \.phase) { group in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  Text("\(group.phaseLabel):")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                  Text(group.models)
                    .font(.caption)
                }
              }
            }
            .fixedSize(horizontal: false, vertical: true)
          }
        } else if let models = modelsSummary {
          metaTile(icon: "brain.head.profile", title: "Models") {
            Text(models.replacingOccurrences(of: "\n", with: ", "))
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        metaTile(icon: "clock.arrow.circlepath", title: "Timeline") {
          if let start = item.phaseTimestamps.recordingStarted,
            let end = item.phaseTimestamps.outputDelivered {
            let total = end.timeIntervalSince(start)
            Text("Total: \(formatDuration(total))")
          } else {
            Text("Recording: \(formatDuration(item.recordingDuration))")
          }
        }

        if let cost = item.cost {
          metaTile(icon: "creditcard", title: "Cost") {
            VStack(alignment: .leading, spacing: 4) {
              Text(formatCurrency(cost.total, currency: cost.currency))
              if let breakdown = cost.breakdown {
                Text("Input tokens: \(breakdown.inputTokens) • Output: \(breakdown.outputTokens)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }

      if let summary = item.personalCorrections,
        !(summary.applied.isEmpty && summary.suggestions.isEmpty) {
        personalCorrectionsSection(summary)
      }
    }
  }

  private func personalCorrectionsSection(_ summary: PersonalLexiconHistorySummary) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Corrections")
        .font(.caption.bold())

      if !summary.contextTags.isEmpty {
        Text("Context tags: \(summary.contextTags.joined(separator: ", "))")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      if let destination = summary.destinationApplication, !destination.isEmpty {
        Text("Destination context: \(destination)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      if !summary.applied.isEmpty {
        correctionsList(
          title: "Applied",
          icon: "wand.and.stars",
          color: .green,
          records: summary.applied
        )
      }

      if !summary.suggestions.isEmpty {
        correctionsList(
          title: "Suggestions",
          icon: "hand.raised",
          color: .orange,
          records: summary.suggestions
        )
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.secondary.opacity(0.08))
    )
  }

  private func correctionsList(
    title: String,
    icon: String,
    color: Color,
    records: [PersonalLexiconCorrectionRecord]
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: icon)
        .font(.caption.bold())
        .foregroundStyle(color)

      ForEach(records) { record in
        correctionsRow(record: record, color: color)
      }
    }
  }

  private func correctionsRow(record: PersonalLexiconCorrectionRecord, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Circle()
          .fill(color)
          .frame(width: 6, height: 6)
        Text("\(record.alias) -> \(record.canonical) (\(record.occurrences)x)")
        Spacer(minLength: 0)
        Text(record.confidence.rawValue.capitalized)
          .font(.caption2)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Capsule().fill(Color.secondary.opacity(0.12)))
      }
      .font(.caption)

      if let reason = record.reason, !reason.isEmpty {
        Text(reason)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }
  private var modelsSummary: String? {
    guard !item.modelsUsed.isEmpty else { return nil }
    let friendly = item.modelsUsed.map { ModelCatalog.friendlyName(for: $0) }
    return friendly.joined(separator: "\n")
  }

  private var modelsSummaryByPhase: String? {
    guard !item.modelUsages.isEmpty else { return nil }

    let groups = Dictionary(grouping: item.modelUsages, by: { $0.phase })
      .sorted { phaseOrder($0.key) < phaseOrder($1.key) }

    let parts = groups.map { phase, usages in
      let models = usages.map { ModelCatalog.friendlyName(for: $0.modelIdentifier) }.joined(separator: ", ")
      return "\(phaseLabel(phase)): \(models)"
    }

    return parts.joined(separator: " • ")
  }

  private struct ModelsByPhase {
    let phase: ModelUsagePhase
    let phaseLabel: String
    let models: String
  }

  private var groupedModelsByPhase: [ModelsByPhase] {
    guard !item.modelUsages.isEmpty else { return [] }

    let groups = Dictionary(grouping: item.modelUsages, by: { $0.phase })
      .sorted { phaseOrder($0.key) < phaseOrder($1.key) }

    return groups.map { phase, usages in
      let models = usages.map { ModelCatalog.friendlyName(for: $0.modelIdentifier) }.joined(separator: ", ")
      return ModelsByPhase(phase: phase, phaseLabel: phaseLabel(phase), models: models)
    }
  }

  private func phaseLabel(_ phase: ModelUsagePhase) -> String {
    switch phase {
    case .transcriptionLive:
      return "Live"
    case .transcriptionBatch:
      return "Batch"
    case .transcriptionLocal:
      return "Local"
    case .postProcessing:
      return "Post-processing"
    }
  }

  private func phaseOrder(_ phase: ModelUsagePhase) -> Int {
    switch phase {
    case .transcriptionLive:
      return 0
    case .transcriptionBatch:
      return 1
    case .transcriptionLocal:
      // Distinct from .transcriptionBatch: equal ranks leave the sort order of
      // the two phases unspecified, so the grouped summary could reorder itself
      // between renders.
      return 2
    case .postProcessing:
      return 3
    }
  }

  private func metaTile<Content: View>(
    icon: String,
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: icon)
          .imageScale(.small)
          .foregroundStyle(Color.brandAccent.opacity(0.8))
        Text(title.uppercased())
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      content()
        .font(.footnote)
        .foregroundStyle(.primary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color.brandAccent.opacity(0.1), lineWidth: 1)
    )
  }

  private func transcriptBox(_ text: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(text)
        .font(.body.monospaced())
      Button {
        copyToPasteboard(text)
      } label: {
        Label("Copy", systemImage: "doc.on.doc")
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
  }

  private var errorSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text("Errors")
          .font(.subheadline.bold())

        Spacer()

        Button {
          openGitHubIssue()
        } label: {
          Label("Open GitHub Issue", systemImage: "ladybug")
        }
        .speakTooltip("Open a prefilled public GitHub issue with safe diagnostics for this failed session.")

        Button {
          copyIssueReport()
        } label: {
          Label("Copy Report", systemImage: "doc.on.clipboard")
        }
        .speakTooltip("Copy the same safe diagnostic report without opening GitHub.")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)

      ForEach(item.errors) { error in
        VStack(alignment: .leading, spacing: 2) {
          Text(error.phase.rawValue.capitalized)
            .font(.caption.bold())
          Text(error.message)
          if let debug = error.debugDescription {
            Text(debug)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.4)))
      }
    }
  }

  private var networkSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Network")
        .font(.subheadline.bold())
      ForEach(item.networkExchanges) { exchange in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("\(exchange.method) \(exchange.url.lastPathComponent)")
              .font(.callout.bold())
            Spacer()
            Text("HTTP \(exchange.responseCode)")
              .font(.caption.bold())
              .foregroundStyle(exchange.responseCode >= 400 ? .red : .secondary)
          }

          Divider()

          if !exchange.requestHeaders.isEmpty {
            Text("Request Headers")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
            Text(formattedHeaders(exchange.requestHeaders))
              .font(.caption2.monospaced())
              .textSelection(.enabled)
          }

          if !exchange.requestBodyPreview.isEmpty {
            Text("Request Body")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
            ScrollView {
              Text(exchange.requestBodyPreview)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
          }

          if !exchange.responseHeaders.isEmpty {
            Text("Response Headers")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
            Text(formattedHeaders(exchange.responseHeaders))
              .font(.caption2.monospaced())
              .textSelection(.enabled)
          }

          if !exchange.responseBodyPreview.isEmpty {
            Text("Response Body")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
            ScrollView {
              Text(exchange.responseBodyPreview)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
          }
        }
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.thinMaterial)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.brandAccent.opacity(0.15), lineWidth: 1)
        )
      }
    }
  }

  @ViewBuilder
  private var promptDisclosureSection: some View {
    if let prompt = item.postProcessingPrompt {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: 10) {
          Text(prompt.modelIdentifier)
            .font(.caption)
            .foregroundStyle(.secondary)
          if let customPrompt = prompt.customPrompt, !customPrompt.isEmpty {
            promptTextBlock(title: "Custom Cleanup Prompt", text: customPrompt)
          }
          promptTextBlock(title: "System Prompt", text: prompt.systemPrompt)
          promptTextBlock(title: "Transcript Payload", text: prompt.userPrompt)
        }
        .padding(.top, 8)
      } label: {
        Label("Post-processing prompt", systemImage: "text.bubble")
          .font(.subheadline.bold())
      }
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(.thinMaterial)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(Color.brandAccent.opacity(0.15), lineWidth: 1)
      )
    }
  }

  private func promptTextBlock(title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption.bold())
        .foregroundStyle(.secondary)
      ScrollView {
        Text(text)
          .font(.caption2.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 180)
      .padding(8)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
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

  private var reprocessTooltip: String {
    let postProcessing = environment.settings.postProcessingEnabled && environment.settings.speedMode == .instant
      ? """
        Post-processing will also use your current post-processing model: \
        \(ModelCatalog.friendlyName(for: environment.settings.postProcessingModel)).
        """
      : "Post-processing is currently off, so only transcription will be rerun."
    return """
      Reprocess reruns this saved audio with your current settings, not the model originally used. \
      It will use \(currentReprocessModelDescription). \(postProcessing)
      """
  }

  private var currentReprocessModelDescription: String {
    let settings = environment.settings
    if settings.transcriptionMode == .localModel {
      let modelName = ModelCatalog.friendlyName(for: settings.localTranscriptionModel)
      if settings.localTranscriptionMode == .streaming {
        return "\(modelName) from Local Batch; Local Streaming candidates are not used for saved-audio reprocessing yet"
      }
      return "\(modelName) from Local Batch"
    }
    return "\(ModelCatalog.friendlyName(for: settings.batchTranscriptionModel)) from Remote Batch"
  }

  private var footerActions: some View {
    HStack(spacing: 12) {
      if let url = item.audioFileURL {
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
          Label("Show in Finder", systemImage: "folder")
        }
        .speakTooltip("Open the folder where this recording lives so you can manage or share the original audio.")

        Button {
          Task { await environment.main.reprocessHistoryItem(item) }
        } label: {
          Label {
            HStack(spacing: 6) {
              Text("Reprocess")
              Image(systemName: "questionmark.circle")
                .imageScale(.small)
            }
          } icon: {
            Image(systemName: "arrow.triangle.2.circlepath")
          }
        }
        .disabled(environment.main.isBusy)
        .speakTooltip(reprocessTooltip)
      }
      if environment.main.isBusy {
        ProgressView()
          .controlSize(.small)
      }
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.small)
    .tint(.accentColor)
  }

  private func copyToPasteboard(_ text: String) {
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(text, forType: .string)
  }

  private func copyIssueReport() {
    copyToPasteboard(HistoryIssueReporter.issueBody(for: item))
  }

  private func openGitHubIssue() {
    guard let url = HistoryIssueReporter.issueURL(for: item) else {
      copyIssueReport()
      return
    }
    if !NSWorkspace.shared.open(url) {
      copyIssueReport()
    }
  }

  private func formatDuration(_ duration: TimeInterval) -> String {
    guard duration.isFinite, duration > 0 else { return "—" }
    let totalHundredths = max(0, Int((duration * 100).rounded()))
    let minutes = totalHundredths / 6000
    let seconds = (totalHundredths / 100) % 60
    let hundredths = totalHundredths % 100
    if minutes > 0 {
      return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    } else {
      return String(format: "%02d.%02d", seconds, hundredths)
    }
  }

  private func formatCurrency(_ value: Decimal, currency: String) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency.isEmpty ? "USD" : currency
    return formatter.string(from: value as NSDecimalNumber) ?? "$0.00"
  }

  private func formattedHeaders(_ headers: [String: String]) -> String {
    headers
      .sorted { $0.key < $1.key }
      .map { "\($0): \($1)" }
      .joined(separator: "\n")
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
