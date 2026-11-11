import Foundation
import SpeakCore

/// Remembers the last transcript whose post-processing failed so ⌘R (or the
/// menu) can polish it again without re-recording. A new session or a
/// successful retry forgets it; a failed retry keeps it for another attempt.
struct PostProcessingRetryStore {
  struct Entry {
    let transcriptionResult: TranscriptionResult
    let recordingSummary: RecordingSummary?
    let personalCorrections: PersonalLexiconHistorySummary?
    let lexiconContext: PersonalLexiconContext
    let originalHistoryItemID: UUID?
  }

  private(set) var pending: Entry?

  var canRetry: Bool { pending != nil }

  /// Offers a retry for the session's transcript. Returns false (and offers
  /// nothing) when the session never produced one.
  mutating func offer(for session: ActiveSession) -> Bool {
    guard let transcriptionResult = session.transcriptionResult else { return false }
    pending = Entry(
      transcriptionResult: transcriptionResult,
      recordingSummary: session.recordingSummary,
      personalCorrections: session.personalCorrections,
      lexiconContext: session.lexiconContext,
      originalHistoryItemID: session.id
    )
    return true
  }

  mutating func clear() {
    pending = nil
  }

  /// The entry to retry now; nil while another session is running.
  func entryToRetry(sessionActive: Bool) -> Entry? {
    sessionActive ? nil : pending
  }
}
