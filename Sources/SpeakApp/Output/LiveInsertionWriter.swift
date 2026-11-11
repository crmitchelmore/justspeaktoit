import ApplicationServices
import Foundation

/// One live insertion strategy for one session: it owns what it wrote and
/// where, and reports failures through its host. `LiveTextInserter` mirrors
/// `insertedText` and `insertedRange` after every call.
@MainActor
protocol LiveInsertionWriter: AnyObject {
  /// The text this session has written into the field.
  var insertedText: String { get }
  /// The UTF-16 range the text occupies after the last successful write, or
  /// nil when the session cannot vouch for where it landed.
  var insertedRange: VoiceEditTextRange? { get }
  /// Brings the field up to date with the full current transcript.
  func update(with newText: String)
  /// Replaces what was written with the final text.
  func finalize(with finalText: String) -> LiveTextInserter.FinalizationResult
}

/// What a live insertion writer needs from the session that owns it.
@MainActor
protocol LiveInsertionHost: AnyObject {
  /// The captured field, nil when it must not be written (see `LiveTextInserter`).
  func focusedTextElement() -> AXUIElement?
  /// The field the ranged path reads and writes.
  func streamingField() -> StreamingTextField?
  /// False (and remembers why) when the app-switch policy forbids writing now.
  func capturedTargetAllowsWrite() -> Bool
  /// Stamps the first-insertion checkpoint.
  func recordAccessibilityWrite()
  func recordError(_ error: Error)
  /// Stops incremental updates; finalization makes one clean pass.
  func pauseIncrementalUpdates(reason: String)
  /// Hands delivery to the standard path unless text already reached the app
  /// (or `textAbsentFromField` proves none of it is there).
  func deferToStandardDelivery(reason: String, error: Error?, textAbsentFromField: Bool)
  var usingClipboardFallback: Bool { get }
  var lastError: Error? { get }
  /// How long to wait before reading back the first streamed write.
  var streamingVerificationDelay: TimeInterval { get }
}
