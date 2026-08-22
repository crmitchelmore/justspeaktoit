import Foundation

/// Immutable description of what a voice-edit session will replace: the
/// captured text and, when the field reported one, its UTF-16 range. The
/// anchor is re-verified against the field before anything is written, so a
/// caret or selection that moved while the user spoke can never cause a
/// different range to be rewritten (issue #673).
struct VoiceEditAnchor: Equatable {
  let text: String
  let range: VoiceEditTextRange?
}

/// Why automatic replacement was not performed and the rewrite was parked on
/// the clipboard for a manual ⌘V instead.
enum VoiceEditClipboardReason: Equatable {
  /// The captured text is no longer where it was: edited, moved, or focus is
  /// in another field.
  case selectionChanged
  /// The field reports neither its text nor its selection, so the anchor
  /// cannot be confirmed.
  case selectionUnverifiable
  /// The captured app or field is gone.
  case targetUnavailable
  /// Accessibility replacement was accepted but the field does not show the
  /// rewrite, so pasting on top could only duplicate it.
  case replacementUnverified
  /// ⌘V was posted but the field still does not show the rewrite (read-only
  /// or ignoring target).
  case pasteUnverified
  /// Accessibility and paste delivery both failed before any write.
  case replacementFailed
  /// Nothing was captured to replace.
  case noCapture
}

/// How a verified anchor relates to the field right now.
enum VoiceEditAnchorState: Equatable {
  /// The captured text is still where it was; `range` is where to write when known.
  case intact(VoiceEditTextRange?)
  /// The captured text is no longer at the anchor.
  case moved
  /// The field cannot report enough to decide.
  case unverifiable

  /// Checks `anchor` against the field, preferring the strongest evidence
  /// available: the text at the recorded range, then the current selection.
  static func evaluate(_ anchor: VoiceEditAnchor, in field: any VoiceEditField) -> VoiceEditAnchorState {
    if let range = anchor.range {
      if let value = field.readValue() {
        return range.substring(of: value) == anchor.text ? .intact(range) : .moved
      }
      if let selection = field.readSelectedRange() {
        guard VoiceEditTextRange(selection) == range, field.readSelectedText() == anchor.text else {
          return .moved
        }
        return .intact(range)
      }
      if let selectedText = field.readSelectedText() {
        return selectedText == anchor.text ? .intact(nil) : .moved
      }
      return .unverifiable
    }
    guard let selectedText = field.readSelectedText() else { return .unverifiable }
    return selectedText == anchor.text ? .intact(nil) : .moved
  }

  /// Stricter check for paste delivery, which replaces whatever is selected
  /// *now*: the current selection itself must still be the captured text.
  static func evaluateSelection(
    _ anchor: VoiceEditAnchor,
    in field: any VoiceEditField
  ) -> VoiceEditAnchorState {
    if let range = anchor.range, let selection = field.readSelectedRange() {
      guard VoiceEditTextRange(selection) == range else { return .moved }
      if let value = field.readValue() {
        return range.substring(of: value) == anchor.text ? .intact(range) : .moved
      }
      return .intact(range)
    }
    guard let selectedText = field.readSelectedText() else { return .unverifiable }
    return selectedText == anchor.text ? .intact(anchor.range) : .moved
  }
}
