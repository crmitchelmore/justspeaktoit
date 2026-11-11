import Foundation

// MARK: - Insertion record for Voice Edit's "last dictation" fallback (issue #673)

extension MainManager {
  /// Remembers where this dictation landed. An unknown range clears the
  /// previous record rather than leaving it in place, so Voice Edit can never
  /// rewrite the range of an older dictation after a newer one was delivered
  /// somewhere it could not track.
  func recordInsertion(of text: String, range: VoiceEditTextRange?, target: TextOutputTarget?) {
    guard let target, let range, !text.isEmpty else {
      insertionRecords.clear()
      return
    }
    insertionRecords.record(
      InsertionRecord(target: target, range: range, text: text, recordedAt: Date())
    )
  }
}
