import Foundation
import SpeakCore
import SwiftUI

// MARK: - Model

/// Owns the persisted speech-insights aggregate for the Mac dashboard.
///
/// The aggregate lives next to the other SpeakApp support files and is updated
/// incrementally: opening the dashboard only folds in sessions recorded since
/// the last visit, so it stays instant with 10k+ history items. Reconciliation
/// against the current history means deletions (manual or retention-driven)
/// drop out of the stats. Everything is computed locally and the aggregate is
/// never part of any sync payload.
@MainActor
final class SpeechInsightsModel: ObservableObject {
  @Published private(set) var summary: SpeechInsightsSummary?
  @Published private(set) var isComputing = false

  private var aggregate: SpeechInsightsAggregate?
  private var refreshTask: Task<Void, Never>?
  private let storageURL: URL

  init(fileManager: FileManager = .default) {
    let supportURL =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
    let folder = supportURL
      .appendingPathComponent("SpeakApp", isDirectory: true)
      .appendingPathComponent("Insights", isDirectory: true)
    if !fileManager.fileExists(atPath: folder.path) {
      try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    storageURL = folder.appendingPathComponent("speech-insights-aggregate.json", isDirectory: false)
  }

  /// Reconciles the aggregate with the current history. Serialized so rapid
  /// history changes cannot interleave; safe to call from `.task`.
  func refresh(using items: [HistoryItem]) {
    let records = items.compactMap(Self.sessionRecord(from:))
    let previous = refreshTask
    refreshTask = Task { [weak self] in
      await previous?.value
      await self?.performRefresh(records: records)
    }
  }

  private func performRefresh(records: [SpeechSessionRecord]) async {
    if summary == nil {
      isComputing = true
    }
    let url = storageURL
    let cached = aggregate
    let (reconciled, newSummary) = await Task.detached(priority: .utility) {
      () -> (SpeechInsightsAggregate, SpeechInsightsSummary) in
      let base = cached ?? Self.loadAggregate(from: url) ?? SpeechInsightsAggregate()
      let reconciled = SpeechInsightsEngine.reconcile(base, with: records)
      if reconciled != base {
        Self.saveAggregate(reconciled, to: url)
      }
      return (reconciled, SpeechInsightsEngine.summary(for: reconciled))
    }.value
    aggregate = reconciled
    summary = newSummary
    isComputing = false
  }

  /// Maps a history item to the engine's session record. Analytics run on the
  /// raw (pre-polish) transcript; the processed text is only a fallback for
  /// items that never stored a raw transcript.
  nonisolated static func sessionRecord(from item: HistoryItem) -> SpeechSessionRecord? {
    let text = item.rawTranscription ?? item.postProcessedTranscription
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return SpeechSessionRecord(
      id: item.id,
      startedAt: item.createdAt,
      text: text,
      duration: effectiveDuration(of: item),
      destinationApplication: item.trigger.destinationApplication,
      modelIdentifier: item.modelUsages.first { $0.phase != .postProcessing }?.modelIdentifier
        ?? item.modelsUsed.first
    )
  }

  private nonisolated static func effectiveDuration(of item: HistoryItem) -> TimeInterval {
    if item.recordingDuration > 0 {
      return item.recordingDuration
    }
    if let start = item.phaseTimestamps.recordingStarted,
      let end = item.phaseTimestamps.recordingEnded {
      return max(0, end.timeIntervalSince(start))
    }
    return 0
  }

  private nonisolated static func loadAggregate(from url: URL) -> SpeechInsightsAggregate? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let aggregate = try? decoder.decode(SpeechInsightsAggregate.self, from: data),
      aggregate.schemaVersion == SpeechInsightsAggregate.currentSchemaVersion
    else { return nil }
    return aggregate
  }

  private nonisolated static func saveAggregate(_ aggregate: SpeechInsightsAggregate, to url: URL) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(aggregate) else { return }
    try? data.write(to: url, options: [.atomic])
  }
}

// MARK: - Section

/// "Speech" section of the dashboard: what you say, how fast, and how often
/// the fillers sneak in. Mirrors the card patterns of the other sections.
struct SpeechInsightsSection: View {
  @Environment(\.appVisualDensity) private var density
  @ObservedObject var model: SpeechInsightsModel

  var body: some View {
    if let summary = model.summary, summary.sessionsAnalyzed > 0 {
      VStack(spacing: density.sectionSpacing) {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: density.gridMinimumWidth), spacing: density.sectionSpacing)],
          spacing: density.sectionSpacing
        ) {
          SpeechTopWordsCard(summary: summary)
          SpeechTopPhrasesCard(summary: summary)
          SpeechVocabularyCard(summary: summary)
        }
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: density.gridMinimumWidth), spacing: density.sectionSpacing)],
          spacing: density.sectionSpacing
        ) {
          SpeechFillerCard(summary: summary)
          SpeechPaceCard(summary: summary)
          SpeechFunStatsCard(summary: summary)
        }
      }
    } else {
      SpeakDensityCard(title: "Speech", systemImage: "waveform.and.mic", tint: Color.brandAccent) {
        if model.isComputing {
          HStack(spacing: density.inlineSpacing) {
            ProgressView()
              .controlSize(.small)
            Text("Analyzing your sessions…")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        } else {
          Text("Record a few sessions to unlock speech insights — top words, pace, and filler trends.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .speakTooltip("Speech analytics are computed on this Mac from your local history and never leave the device.")
    }
  }
}
