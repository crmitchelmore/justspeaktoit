import Foundation
import SpeakCore
import SwiftUI

// MARK: - Model

/// The Mac's speech-insights model: the shared `SpeechInsightsModel` persisted
/// next to the other SpeakApp support files and fed from `HistoryItem`s.
extension SpeechInsightsModel {
  convenience init(fileManager: FileManager = .default) {
    let supportURL =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
    let folder = supportURL.appendingPathComponent(ReleaseTrain.current.supportDirectory, isDirectory: true)
    self.init(storageURL: Self.storageURL(inSupportDirectory: folder, fileManager: fileManager))
  }

  /// Reconciles the aggregate with the current history.
  func refresh(using items: [HistoryItem]) {
    refresh(records: items.compactMap(Self.sessionRecord(from:)))
  }

  /// Maps a history item to the engine's session record.
  nonisolated static func sessionRecord(from item: HistoryItem) -> SpeechSessionRecord? {
    SpeechSessionRecord(
      historyID: item.id,
      createdAt: item.createdAt,
      rawTranscription: item.rawTranscription,
      postProcessedTranscription: item.postProcessedTranscription,
      recordingDuration: item.recordingDuration,
      phaseTimestamps: item.phaseTimestamps,
      destinationApplication: item.trigger.destinationApplication,
      modelIdentifier: item.modelUsages.first { $0.phase != .postProcessing }?.modelIdentifier
        ?? item.modelsUsed.first
    )
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
