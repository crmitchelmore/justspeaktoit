import AppKit
import ApplicationServices
import Foundation
import SpeakCore
import os.log

struct TextOutputResult {
  let method: HistoryTrigger.OutputMethod
  let error: Error?
  let warning: Error?
  /// Where the text landed in the focused field, when the delivery path can
  /// tell. Voice Edit's "last dictation" fallback edits this exact range
  /// (issue #673).
  let insertedRange: VoiceEditTextRange?
  /// The app/field delivery actually used when it was redirected away from the
  /// captured target because the user had switched apps and chose to insert
  /// into the app they're in now. Nil when delivery used the requested target.
  var redirectedTarget: TextOutputTarget?
  /// True when, at delivery time, the user was in a different app from the one
  /// where recording started (or that app had quit) and delivery still
  /// targeted the original app, as configured.
  var focusMovedToOtherApplication = false

  init(
    method: HistoryTrigger.OutputMethod,
    error: Error?,
    warning: Error? = nil,
    insertedRange: VoiceEditTextRange? = nil
  ) {
    self.method = method
    self.error = error
    self.warning = warning
    self.insertedRange = insertedRange
  }
}

func currentSystemFocusedElement() -> AXUIElement? {
  let systemWideElement = AXUIElementCreateSystemWide()
  var rawFocused: CFTypeRef?
  let copyStatus = AXUIElementCopyAttributeValue(
    systemWideElement,
    kAXFocusedUIElementAttribute as CFString,
    &rawFocused
  )
  guard copyStatus == .success, let rawFocused else { return nil }
  return unsafeBitCast(rawFocused, to: AXUIElement.self)
}

@MainActor
protocol TextOutputting {
  func output(text: String, target: TextOutputTarget?) -> TextOutputResult
}

extension TextOutputting {
  func output(text: String) -> TextOutputResult {
    output(text: text, target: .capture())
  }
}

enum TextOutputError: LocalizedError {
  case accessibilityPermissionMissing
  case unableToFindFocusedElement
  case unableToSetValue(AXError)
  case unableToVerifyInsertion
  case clipboardWriteFailed
  case targetApplicationUnavailable
  case pasteShortcutUnavailable
  case capturedFieldUnavailable
  case capturedFieldChanged
  /// The user switched away from the app where recording started and chose
  /// to insert only while that app is in front. Carries the app's name.
  case originalApplicationNotInFront(String?)
  /// Delivery was redirected to the app in front, but the user switched apps
  /// again before the text could be written.
  case destinationApplicationChanged
  var errorDescription: String? {
    switch self {
    case .accessibilityPermissionMissing:
      return "Accessibility permission is required to insert text directly."
    case .unableToFindFocusedElement:
      return "No focused field was detected."
    case .unableToSetValue(let status):
      return "Unable to set text via accessibility APIs (status: \(status.rawValue))."
    case .unableToVerifyInsertion:
      return "Unable to verify that text was inserted into the focused field."
    case .clipboardWriteFailed:
      return "Failed to write to the clipboard."
    case .targetApplicationUnavailable:
      return "The original app is no longer available. The transcript was kept on the clipboard."
    case .pasteShortcutUnavailable:
      return "Unable to paste into the original app. The transcript was kept on the clipboard."
    case .capturedFieldUnavailable:
      return "The field where recording started could not be identified. "
        + "The transcript was kept on the clipboard."
    case .capturedFieldChanged:
      return "The focused field changed since recording started. "
        + "The transcript was kept on the clipboard."
    case .originalApplicationNotInFront(let name):
      return "You'd switched away from \(name ?? "the app where recording started") before final delivery. "
        + "The transcript was kept on the clipboard."
    case .destinationApplicationChanged:
      return "You switched apps again before final delivery. "
        + "The transcript was kept on the clipboard."
    }
  }

  /// The description without app names, for History and anything exported
  /// from it (such as public GitHub issue prefills).
  var historySafeDescription: String {
    if case .originalApplicationNotInFront = self {
      return Self.originalApplicationNotInFront(nil).errorDescription ?? ""
    }
    return errorDescription ?? ""
  }
}
