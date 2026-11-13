import AppKit
import ApplicationServices
import Foundation
import SpeakCore
import os.log

private let logger = SpeakLogger.logger(category: "LiveTextInserter")

/// Experimental ranged streaming insertion (issue #611): keeps the stable
/// prefix of the streamed text untouched and patches only the differing tail
/// through `kAXSelectedTextRange` + `kAXSelectedText`. Owns the streamed
/// region (its anchor, the selection it replaces, the field's pre-session
/// text) for one session; any failure pauses or hands back to the standard
/// one-shot delivery without ever duplicating text.
@MainActor
final class RangedStreamingInserter: LiveInsertionWriter {
  /// The text this session has streamed into the field.
  private(set) var insertedText = ""
  /// Where the finalised region sits, once finalization applied it.
  private(set) var insertedRange: VoiceEditTextRange?
  /// Whether an accessibility write has landed in this session.
  private(set) var hasWritten = false
  private var firstInsertionVerified = false

  /// UTF-16 offset in the target field where the streamed region begins.
  /// Captured from the caret on first insert.
  private var anchorUTF16: Int?
  /// UTF-16 length of the selection present when the region was anchored. The
  /// first ranged replacement consumes it so streaming replaces a selection
  /// exactly like the standard insertion path does.
  private var pendingSelectionUTF16 = 0
  /// The field's contents when the region was anchored, before this session
  /// wrote anything: the only evidence that streamed text is genuinely absent
  /// (rather than altered by the app), and for rejecting a re-anchor onto
  /// identical pre-existing text.
  private var baselineFieldText: String?
  /// The anchor and selection length as first captured, before any re-sync.
  /// Cancellation rollback rebuilds the expected field from these.
  private var originalSelection: CFRange?
  /// The document the field showed when the region was anchored. Rollback
  /// deletes only while the field provably still shows that document.
  private var originalDocumentIdentity: String?
  /// Whether a read-back has confirmed this session's text in the field. After
  /// that, finding it absent means focus moved to another field, not that the
  /// text never landed, so a one-shot paste into the new field would be wrong.
  private var confirmedInField = false

  private weak var host: LiveInsertionHost?

  init(host: LiveInsertionHost) {
    self.host = host
  }

  /// Publishes the streamed region, holding `length` UTF-16 units, as this
  /// session's final insertion range.
  private func recordRegion(length: Int) {
    insertedRange = anchorUTF16.map { VoiceEditTextRange(location: $0, length: length) }
  }

  /// Patches the target field so it contains `newText` at the streamed region.
  func update(with newText: String) {
    guard let host else { return }
    guard let field = host.streamingField() else {
      abandon(reason: "no focused element", error: TextOutputError.unableToFindFocusedElement)
      return
    }

    guard regionIsWritable(on: field, host: host) else { return }

    let diff = StreamingTextReconciler.diff(from: insertedText, to: newText)
    guard !diff.isNoOp else { return }
    guard apply(diff, on: field) else { return }
    insertedText = newText

    if !firstInsertionVerified {
      verifyFirstInsertion(on: field)
    }
  }

  /// Anchors the region on the first write, or re-validates it before every
  /// later patch: another edit may have moved or removed the streamed text
  /// since the last update. False once the update must not write.
  private func regionIsWritable(on field: StreamingTextField, host: LiveInsertionHost) -> Bool {
    guard anchorUTF16 != nil else {
      // First insert: anchor the streamed region at the current caret, keeping
      // any selection so the first replacement consumes it.
      guard let selection = field.readSelectedRange() else {
        abandon(reason: "cannot read caret position", error: nil)
        return false
      }
      anchorUTF16 = selection.location
      pendingSelectionUTF16 = max(0, selection.length)
      originalSelection = CFRange(location: selection.location, length: pendingSelectionUTF16)
      baselineFieldText = field.readValue()
      originalDocumentIdentity = field.readDocumentIdentity()
      return true
    }
    guard !insertedText.isEmpty else { return true }
    switch inspectRegion(on: field) {
    case .matched:
      return true
    case .absent:
      streamedTextWentAbsent()
      return false
    case .unknown:
      host.pauseIncrementalUpdates(reason: "streamed region could not be verified")
      return false
    }
  }

  /// Text confirmed on screen earlier and now missing means focus moved to a
  /// different field, so pause; otherwise the first write never landed and the
  /// standard one-shot delivery is safe.
  private func streamedTextWentAbsent() {
    if confirmedInField {
      host?.pauseIncrementalUpdates(reason: "streamed text left the focused field")
    } else {
      abandon(reason: "streamed text is no longer in the field", error: nil, textAbsentFromField: true)
    }
  }

  /// One clean final pass: transform the streamed region into the final
  /// polished text. Never re-pastes on failure — if text already reached the
  /// app the streamed transcript is left in place rather than duplicated.
  func finalize(with finalText: String) -> LiveTextInserter.FinalizationResult {
    guard let host else { return .deferred }
    // Nothing ever streamed: hand the whole delivery to the standard path.
    guard !insertedText.isEmpty || hasWritten else {
      host.deferToStandardDelivery(reason: "nothing streamed", error: nil, textAbsentFromField: true)
      return .deferred
    }

    guard let field = host.streamingField() else {
      // Deliberately .applied, not .failed. Every partial was written and
      // verified before this point, so the user's full transcript is in the
      // field; only the final polish delta may be missing. Reporting failure
      // would suppress the "Delivered" HUD and record a HistoryError for a
      // delivery that visibly succeeded, which misleads more than the mild
      // inaccuracy of calling a near-final transcript delivered. Contrast the
      // .unknown case below, which fails because the field may still hold only
      // the first partial.
      logger.warning("Streaming finalize: focused element lost, keeping streamed text")
      host.recordError(TextOutputError.unableToFindFocusedElement)
      recordRegion(length: insertedText.utf16.count)
      return .applied
    }

    // Only report success for text that is verifiably still where this session
    // put it, and only patch a region we can still locate.
    switch inspectRegion(on: field) {
    case .matched:
      break
    case .absent where confirmedInField:
      // The text was seen in the field earlier, so the focused field is now a
      // different one (another note or document). Pasting the whole transcript
      // there would split it across two places; keep it on the clipboard and
      // leave the original field's streamed words untouched.
      host.recordError(TextOutputError.capturedFieldChanged)
      logger.info("Streaming finalize: focused field changed, keeping final on the clipboard")
      return .clipboard(.capturedFieldChanged)
    case .absent:
      // Nothing from this session is on screen, so one standard delivery of the
      // final text is safe and cannot duplicate anything.
      insertedText = ""
      host.deferToStandardDelivery(
        reason: "Streaming finalize: streamed text absent", error: nil, textAbsentFromField: true
      )
      return .deferred
    case .unknown:
      // Cannot prove where the text is: keep whatever is there rather than risk
      // overwriting unrelated content or duplicating the delivery.
      //
      // Unlike the two .applied paths, this one genuinely fails. Reaching
      // .unknown means the region stopped verifying, which is exactly what
      // happens when the app accepted the first partial and then silently
      // refused every later patch — the field may hold only that first partial,
      // not the transcript. Announcing "Delivered" over a truncated transcript
      // would hide real data loss, so the caller is told the delivery failed.
      host.recordError(TextOutputError.unableToVerifyInsertion)
      logger.warning("Streaming finalize: region unverified, keeping streamed text")
      return .failed(TextOutputError.unableToVerifyInsertion)
    }

    let diff = StreamingTextReconciler.diff(from: insertedText, to: finalText)
    if diff.isNoOp {
      recordRegion(length: finalText.utf16.count)
      return .applied
    }

    if apply(diff, on: field) {
      insertedText = finalText
      recordRegion(length: finalText.utf16.count)
      return .applied
    }
    if host.usingClipboardFallback {
      // No text ever reached the app, so the one-shot standard delivery is safe.
      return .deferred
    }
    // A write already landed but the final patch failed: keep the streamed
    // transcript as-is instead of risking a duplicate insert.
    //
    // Deliberately .applied, for the same reason as the lost-focus path above.
    // The region was matched moments ago, so the streamed transcript is intact
    // in the field and only the final polish delta is missing. Failing here
    // would suppress the "Delivered" HUD and record a HistoryError against a
    // delivery the user can see, which is a worse report than the mild
    // inaccuracy of treating a near-final transcript as delivered.
    logger.warning("Streaming finalize failed after writes; keeping streamed text")
    recordRegion(length: insertedText.utf16.count)
    return .applied
  }

  /// Selects `diff`'s range (offset by the region anchor) and replaces it.
  /// Returns false after routing any failure through `abandon`.
  private func apply(_ diff: StreamingTextDiff, on field: StreamingTextField) -> Bool {
    guard let host else { return false }
    guard let anchor = anchorUTF16 else {
      abandon(reason: "streaming anchor missing", error: nil)
      return false
    }

    let range = CFRange(
      location: anchor + diff.replaceLocationUTF16,
      length: diff.replaceLengthUTF16 + pendingSelectionUTF16
    )
    guard host.capturedTargetAllowsWrite() else { return false }
    let rangeStatus = field.setSelectedRange(range)
    guard rangeStatus == .success else {
      abandon(
        reason: "selecting replacement range failed (AXError \(rangeStatus.rawValue))",
        error: TextOutputError.unableToSetValue(rangeStatus)
      )
      return false
    }

    guard host.capturedTargetAllowsWrite() else { return false }
    let insertStatus = field.setSelectedText(diff.replacement)
    guard insertStatus == .success else {
      // The selection landed but the replacement did not: leaving the user's
      // text highlighted would make their next keystroke delete it, so collapse
      // back to a caret at the region start before giving up.
      if host.capturedTargetAllowsWrite() {
        _ = field.setSelectedRange(CFRange(location: range.location, length: 0))
      }
      abandon(
        reason: "replacing selected text failed (AXError \(insertStatus.rawValue))",
        error: TextOutputError.unableToSetValue(insertStatus)
      )
      return false
    }

    // The diff always extends to the end of the streamed region, so the caret
    // lands at the region end naturally after the replacement.
    pendingSelectionUTF16 = 0
    hasWritten = true
    host.recordAccessibilityWrite()
    return true
  }

  /// Reads back the streamed region once after the first write. On mismatch the
  /// session either falls back safely (nothing landed) or pauses incremental
  /// updates, so a misbehaving AX implementation can never garble or duplicate
  /// text.
  private func verifyFirstInsertion(on field: StreamingTextField) {
    guard anchorUTF16 != nil else { return }
    // Give the target app a brief moment to apply the change before reading back.
    Thread.sleep(forTimeInterval: host?.streamingVerificationDelay ?? 0)

    switch inspectRegion(on: field) {
    case .matched:
      firstInsertionVerified = true
      logger.debug("First streaming insertion verified")
    case .absent:
      abandon(
        reason: "first streaming insertion never reached the field",
        error: TextOutputError.unableToVerifyInsertion,
        textAbsentFromField: true
      )
    case .unknown:
      host?.recordError(TextOutputError.unableToVerifyInsertion)
      host?.pauseIncrementalUpdates(reason: "streaming verification failed")
    }
  }

  /// Confirms the streamed region still holds what this session believes it
  /// wrote, re-anchoring when the app moved the text. `.absent` is proof that
  /// nothing from this session is on screen, so a single standard delivery is
  /// safe; `.unknown` means no write may be attempted.
  private func inspectRegion(on field: StreamingTextField) -> StreamingRegionResolver.State {
    guard let anchor = anchorUTF16 else { return .unknown }
    guard let fieldText = field.readValue() else { return .unknown }

    let state = StreamingRegionResolver.resolve(
      fieldText: fieldText,
      expected: insertedText,
      anchor: anchor,
      baselineFieldText: baselineFieldText
    )
    if case let .matched(resolvedAnchor) = state {
      if !insertedText.isEmpty { confirmedInField = true }
      if resolvedAnchor != anchor {
        anchorUTF16 = resolvedAnchor
        logger.debug("Streaming anchor re-synced to \(resolvedAnchor)")
      }
    }
    return state
  }

  /// Streaming failure policy: if nothing has reached the app yet, fall back to
  /// the standard one-shot delivery; if text is already on screen, only pause
  /// incremental updates (finalize will do a single clean patch, never a paste).
  private func abandon(reason: String, error: Error?, textAbsentFromField: Bool = false) {
    guard let host else { return }
    if let error {
      host.recordError(error)
    }
    if hasWritten, !textAbsentFromField {
      host.pauseIncrementalUpdates(reason: reason)
    } else {
      if textAbsentFromField { insertedText = "" }
      host.deferToStandardDelivery(
        reason: "streaming aborted: \(reason)",
        error: error,
        textAbsentFromField: textAbsentFromField
      )
    }
  }
}

// MARK: - Cancellation rollback (issue #1561)

extension RangedStreamingInserter {
  /// Restores the field to its pre-recording text: the streamed region is
  /// replaced by whatever selection it consumed, and that selection (or caret)
  /// is put back. Writes only when the field still shows the document it was
  /// anchored in and holds, code unit for code unit, the pre-recording text
  /// with this session's text spliced in at the original anchor. Any user
  /// edit, a re-anchored region, a normalisation change, or a different note
  /// behind the same element (#664) leaves the document untouched.
  func rollBack() -> LiveTextInserter.RollbackResult {
    guard hasWritten, !insertedText.isEmpty else { return .nothingInserted }
    guard let host, let field = host.streamingField() else {
      return .kept(reason: "the target field is no longer available")
    }
    // Equal text does not prove the same document: Notes reuses one element
    // for every note, so an identically populated note would pass every text
    // check below. Without a document identity to compare, keep the text.
    guard let document = originalDocumentIdentity, field.readDocumentIdentity() == document else {
      return .kept(reason: "the target document's identity could not be verified")
    }
    guard let original = originalSelection, let baseline = baselineFieldText,
          let replaced = StreamingRegionResolver.utf16Substring(
            of: baseline, location: original.location, length: original.length
          ),
          let prefix = StreamingRegionResolver.utf16Substring(of: baseline, location: 0, length: original.location),
          let suffix = StreamingRegionResolver.utf16Substring(
            of: baseline,
            location: original.location + original.length,
            length: baseline.utf16.count - original.location - original.length
          )
    else {
      return .kept(reason: "the field's text before recording is unknown")
    }
    guard let current = field.readValue() else {
      return .kept(reason: "the target field could not be read")
    }
    // Exact UTF-16 comparison: String == treats canonically equivalent
    // spellings as equal, but the AX ranges below are UTF-16 offsets, so a
    // renormalised prefix would shift the deletion onto neighbouring text.
    guard current.utf16.elementsEqual((prefix + insertedText + suffix).utf16) else {
      return .kept(reason: "the document changed after the text was streamed")
    }

    let region = CFRange(location: prefix.utf16.count, length: insertedText.utf16.count)
    let regionEnd = CFRange(location: region.location + region.length, length: 0)
    guard host.capturedTargetAllowsWrite(), field.setSelectedRange(region) == .success else {
      return .kept(reason: "the streamed region could not be selected")
    }
    // The app may have edited the field since it was read; replace only while
    // the selection still covers exactly the streamed text.
    guard selection(on: field, covers: region, expecting: current, in: document) else {
      _ = field.setSelectedRange(regionEnd)
      return .kept(reason: "the document changed before the streamed text could be removed")
    }
    guard host.capturedTargetAllowsWrite(), field.setSelectedText(replaced) == .success else {
      // Never leave the streamed words highlighted for the next keystroke.
      _ = field.setSelectedRange(regionEnd)
      return .kept(reason: "the target app refused to remove the streamed text")
    }
    _ = field.setSelectedRange(original)

    insertedText = ""
    insertedRange = nil
    guard let restored = field.readValue(), restored.utf16.elementsEqual(baseline.utf16) else {
      return .kept(reason: "the removal could not be confirmed by reading the field back")
    }
    return .removed
  }

  private func selection(
    on field: StreamingTextField, covers region: CFRange, expecting text: String, in document: String
  ) -> Bool {
    guard let selected = field.readSelectedRange(), let value = field.readValue() else { return false }
    return selected.location == region.location && selected.length == region.length
      && value.utf16.elementsEqual(text.utf16) && field.readDocumentIdentity() == document
  }
}
