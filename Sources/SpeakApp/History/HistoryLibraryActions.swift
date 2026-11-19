import AVFoundation
import Foundation
import SpeakCore

/// Owns the History page's library-wide actions: importing audio files for
/// transcription and clearing every entry, with the busy and alert state they
/// present.
@MainActor
final class HistoryLibraryActions: ObservableObject {
  @Published var showClearAllConfirmation = false
  @Published var showImportFiles = false
  @Published var showImportAlert = false
  @Published private(set) var isClearingAll = false
  @Published private(set) var isImportingFiles = false
  @Published private(set) var importAlertMessage: String?

  /// Importing waits for any clear-all, earlier import or live session.
  func importDisabled(isSessionBusy: Bool) -> Bool {
    self.isClearingAll || self.isImportingFiles || isSessionBusy
  }

  func clearAllDisabled(hasHistory: Bool) -> Bool {
    !hasHistory || self.isClearingAll || self.isImportingFiles
  }

  func clearAllHistory(deleteRecordings: Bool, in environment: AppEnvironment) async {
    self.isClearingAll = true
    if deleteRecordings {
      let recordings = await environment.audio.listRecordings()
      for recording in recordings {
        await environment.audio.removeRecording(at: recording.url)
      }
    }
    await environment.history.removeAll()
    self.isClearingAll = false
  }

  func presentImportError(_ message: String) {
    self.importAlertMessage = message
    self.showImportAlert = true
  }

  /// Copies each file into the recordings folder and reprocesses it as a new
  /// history entry with the current transcription settings.
  func importAudioFiles(_ urls: [URL], in environment: AppEnvironment) async {
    self.isImportingFiles = true
    defer { self.isImportingFiles = false }

    guard await environment.transcription.hasValidBatchAPIKey() else {
      self.presentImportError("Batch transcription requires an API key. Add one in Settings › API Keys.")
      return
    }

    for url in urls {
      let accessed = url.startAccessingSecurityScopedResource()
      defer {
        if accessed {
          url.stopAccessingSecurityScopedResource()
        }
      }

      do {
        let importedURL = try await environment.audio.importRecording(from: url)
        let duration = (try? AVAudioPlayer(contentsOf: importedURL).duration) ?? 0
        await environment.main.reprocessHistoryItem(Self.importPlaceholder(audioURL: importedURL, duration: duration))
      } catch {
        self.presentImportError("Failed to import \(url.lastPathComponent): \(error.localizedDescription)")
      }
    }
  }

  private static func importPlaceholder(audioURL: URL, duration: TimeInterval) -> HistoryItem {
    HistoryItem(
      modelsUsed: [],
      rawTranscription: nil,
      postProcessedTranscription: nil,
      recordingDuration: duration,
      cost: nil,
      audioFileURL: audioURL,
      networkExchanges: [],
      events: [],
      phaseTimestamps: PhaseTimestamps(
        recordingStarted: nil,
        recordingEnded: nil,
        transcriptionStarted: nil,
        transcriptionEnded: nil,
        postProcessingStarted: nil,
        postProcessingEnded: nil,
        outputDelivered: nil
      ),
      trigger: HistoryTrigger(
        gesture: .uiButton,
        hotKeyDescription: "Import",
        outputMethod: .none,
        destinationApplication: nil
      ),
      personalCorrections: nil,
      errors: [],
      source: .importedFile
    )
  }
}
