import SpeakCore
import Foundation

/// Start, stop, cancel and retry requests from the UI, the Escape key and Shortcuts.
extension MainManager {
  func toggleRecordingFromUI() {
    guard !isEndingSession else { return }
    if activeSession == nil {
      let triggerTiming = SessionTriggerTiming.nonHotKey()
      Task { await startSession(trigger: .uiButton, triggerTiming: triggerTiming) }
    } else {
      Task { await endSession(trigger: .uiButton) }
    }
  }

  // MARK: - Automation (App Intents / Shortcuts)

  /// Whether a dictation session is currently active. Automation callers use
  /// this instead of `state` so an in-flight stop still reads as active.
  var isDictationSessionActive: Bool {
    activeSession != nil
  }

  /// Starts a dictation session on behalf of a Shortcuts action, reusing the
  /// exact hotkey/UI session pipeline. Returns false when no session started;
  /// `state` and `missingLiveAPIKeyAlert` carry the reason.
  @discardableResult
  func startDictationFromAutomation() async -> Bool {
    await startSession(trigger: .automation)
    return activeSession != nil
  }

  /// Ends the active dictation session on behalf of a Shortcuts action and
  /// returns the delivered history item, or nil when the session failed (the
  /// failure message is available via `state` / `lastErrorMessage`).
  func stopDictationFromAutomation() async -> HistoryItem? {
    await endSession(trigger: .automation)
    if case .completed(let item) = state {
      return item
    }
    return nil
  }

  /// Re-transcribes a History item's audio (or an imported file) into a new
  /// History entry without delivering it.
  func reprocessHistoryItem(_ item: HistoryItem) async {
    await reprocessing.reprocess(item)
  }

  func retryPostProcessing() {
    guard let retryData = retryStore.entryToRetry(sessionActive: activeSession != nil) else { return }
    Task { await reprocessing.retryPostProcessing(with: retryData) }
  }

  func userRequestedStopDueToError() {
    guard activeSession != nil else { return }
    cancelRecordingByUser(reason: "User cancelled")
  }

  func cancelRecordingWithEscape() {
    guard appSettings.cancelRecordingOnEscape, state == .recording, activeSession != nil else { return }
    logger.info("Cancelling recording via Escape key")
    cancelRecordingByUser(reason: "Cancelled by user (Escape)")
  }

  /// A user cancellation either keeps the audio as a cancelled History entry
  /// that can be reprocessed later, or deletes it and records nothing.
  private func cancelRecordingByUser(reason: String) {
    activeSession?.errors.append(HistoryError(phase: .recording, message: reason, debugDescription: nil))
    cleanupAfterFailure(
      message: "Recording cancelled", preserveFile: appSettings.keepAudioOnCancel,
      transcriptPolicy: .discard, historyRequiresAudio: true
    )
  }
}
