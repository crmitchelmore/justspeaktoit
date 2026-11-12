import Foundation
import SpeakCore
import SpeakSync

/// CloudKit History and Compare Models sync, plus notifications for
/// transcripts arriving from an iPhone or Apple Watch (#1007). The app
/// environment retains this for the whole run: the sync engines only hold
/// their delegates weakly, so without an owner the adapters deallocate after
/// bootstrap and sync stops (#685).
@MainActor
struct AppCloudSync {
  /// Bridges HistoryManager mutations to CloudKit history sync.
  let history: MacHistorySyncAdapter
  /// The Compare Models rounds' CloudKit bridge (#1101).
  let comparisons: MacComparisonSyncAdapter
  /// Posts and acts on notifications for transcripts from other devices.
  let remoteTranscripts: RemoteTranscriptDelivery

  init(
    history historyManager: HistoryManager,
    comparisonRounds: ComparisonRoundStore,
    permissions: PermissionsManager,
    settings: AppSettings,
    defaults: UserDefaults
  ) {
    history = MacHistorySyncAdapter(historyManager: historyManager, defaults: defaults)
    // Phone and watch captures arriving through CloudKit history sync (#1007).
    let remoteTranscripts = RemoteTranscriptDelivery(
      settings: settings,
      paste: { text in
        SmartTextOutput(permissionsManager: permissions, appSettings: settings)
          .output(text: text, target: nil)
      },
      // A notification stays actionable across a relaunch; its identifier is
      // the History entry id, so the durable local entry answers the action
      // even when the posting process is long gone.
      transcriptForEntry: { [weak historyManager] entryID in
        guard let item = historyManager?.items.first(where: { $0.id == entryID }) else { return nil }
        return item.postProcessedTranscription ?? item.rawTranscription
      }
    )
    self.remoteTranscripts = remoteTranscripts
    history.onRemoteEntryArrived = { [weak remoteTranscripts] entry, isNew in
      remoteTranscripts?.handle(entry: entry, isNewToThisMac: isNew)
    }
    comparisons = MacComparisonSyncAdapter(store: comparisonRounds)
  }
}
