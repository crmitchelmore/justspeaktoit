import AppKit
import ApplicationServices
import Foundation
import SpeakCore

/// Replaces a captured selection with the LLM rewrite, and only that
/// selection: the anchor is re-verified against the field before any write,
/// every delivery path reads the field back where it can, and a rewrite that
/// could not be applied verifiably is parked on the clipboard instead of being
/// reported as "Edited" (issue #673).
@MainActor
final class VoiceEditReplacementService {
  typealias Capture = VoiceEditSelectionService.Capture
  typealias Outcome = VoiceEditOrchestrator.ReplacementOutcome
  typealias PasteShortcut = @MainActor (PasteTextOutput.EventDestination) -> Bool

  private let permissionsManager: PermissionsManager
  private let fieldResolver: any VoiceEditFieldResolving
  private let pasteboard: NSPasteboard
  private let pasteShortcut: PasteShortcut
  /// How long to wait for the app to apply an accessibility write before
  /// reading it back.
  private let accessibilityVerificationDelay: Duration
  /// How long to wait between read-backs after posting ⌘V, and how many times.
  /// Slow (Electron) targets need several hundred milliseconds.
  private let pasteVerificationInterval: Duration
  private let pasteVerificationAttempts: Int

  init(
    permissionsManager: PermissionsManager,
    fieldResolver: any VoiceEditFieldResolving = AccessibilityVoiceEditFieldResolver(),
    pasteboard: NSPasteboard = .general,
    pasteShortcut: @escaping PasteShortcut = VoiceEditKeyboardShortcuts.postPaste,
    accessibilityVerificationDelay: Duration = .milliseconds(50),
    pasteVerificationInterval: Duration = .milliseconds(100),
    pasteVerificationAttempts: Int = 10
  ) {
    self.permissionsManager = permissionsManager
    self.fieldResolver = fieldResolver
    self.pasteboard = pasteboard
    self.pasteShortcut = pasteShortcut
    self.accessibilityVerificationDelay = accessibilityVerificationDelay
    self.pasteVerificationInterval = pasteVerificationInterval
    self.pasteVerificationAttempts = max(1, pasteVerificationAttempts)
  }

  func replace(_ capture: Capture, with rewrite: String) async -> Outcome {
    guard capture.target.isApplicationRunning else {
      return park(rewrite, reason: .targetUnavailable)
    }
    switch await replaceViaAccessibility(capture, rewrite: rewrite) {
    case .replaced:
      return .replaced
    case .parked(let reason):
      return park(rewrite, reason: reason)
    case .notAttempted:
      return await pasteReplacement(capture, rewrite: rewrite)
    }
  }

  /// Terminal fallback when no capture is available to replace: park the
  /// rewrite on the clipboard so the HUD's "Press ⌘V" guidance is accurate.
  func leaveOnClipboard(_ rewrite: String) -> Outcome {
    park(rewrite, reason: .noCapture)
  }

  // MARK: - Accessibility path

  private enum AccessibilityAttempt {
    case replaced
    case parked(VoiceEditClipboardReason)
    /// Nothing was written; paste delivery may still be tried.
    case notAttempted
  }

  private func replaceViaAccessibility(_ capture: Capture, rewrite: String) async -> AccessibilityAttempt {
    guard permissionsManager.status(for: .accessibility).isGranted, let field = capture.field else {
      return .notAttempted
    }
    switch anchorPreflight(capture, field: field, forPaste: false) {
    case .park(let reason):
      return .parked(reason)
    case .ready(let range):
      return await writeViaAccessibility(rewrite, at: range, in: field)
    }
  }

  private func writeViaAccessibility(
    _ rewrite: String,
    at range: VoiceEditTextRange?,
    in field: any VoiceEditField
  ) async -> AccessibilityAttempt {
    let valueBeforeWrite = field.readValue()
    if let range, field.setSelectedRange(range.cfRange) != .success {
      return .notAttempted
    }
    // A rejected write leaves the anchored range selected on purpose: that is
    // exactly the selection the paste fallback must replace.
    guard field.setSelectedText(rewrite) == .success else { return .notAttempted }

    // A write was accepted: from here on, pasting could only duplicate it.
    try? await Task.sleep(for: accessibilityVerificationDelay)
    guard let after = field.readValue() else { return .replaced }
    let landed = Self.rewriteShows(rewrite, at: range, before: valueBeforeWrite, after: after)
    return landed ? .replaced : .parked(.replacementUnverified)
  }

  // MARK: - Anchor preflight

  private enum Preflight {
    case ready(VoiceEditTextRange?)
    case park(VoiceEditClipboardReason)
  }

  /// Confirms focus is still the captured field in the captured process and
  /// that the anchor still holds the captured text. Paste delivery uses the
  /// stricter selection check because ⌘V replaces whatever is selected *now*.
  private func anchorPreflight(_ capture: Capture, field: any VoiceEditField, forPaste: Bool) -> Preflight {
    guard let focused = fieldResolver.focusedField(), focused.isSameField(as: field) else {
      return .park(.selectionChanged)
    }
    if let expected = capture.target.processIdentifier, let actual = field.processIdentifier, expected != actual {
      return .park(.selectionChanged)
    }
    let state = forPaste
      ? VoiceEditAnchorState.evaluateSelection(capture.anchor, in: field)
      : VoiceEditAnchorState.evaluate(capture.anchor, in: field)
    switch state {
    case .intact(let range):
      return .ready(range)
    case .moved:
      return .park(.selectionChanged)
    case .unverifiable:
      return .park(.selectionUnverifiable)
    }
  }

  // MARK: - Paste path

  private func pasteReplacement(_ capture: Capture, rewrite: String) async -> Outcome {
    guard DistributionChannel.current.supportsAccessibilityTextInsertion else {
      return park(rewrite, reason: .replacementFailed)
    }
    let destination = PasteTextOutput.eventDestination(for: capture.target)
    guard destination != .none else {
      return park(rewrite, reason: .targetUnavailable)
    }
    guard let field = capture.field else {
      return park(rewrite, reason: .selectionUnverifiable)
    }
    if case .park(let reason) = anchorPreflight(capture, field: field, forPaste: true) {
      return park(rewrite, reason: reason)
    }

    let saved = PasteboardSnapshot(reading: pasteboard)
    let valueBeforePaste = field.readValue()
    pasteboard.clearContents()
    guard pasteboard.setString(rewrite, forType: .string), pasteShortcut(destination) else {
      saved.restore(to: pasteboard)
      return park(rewrite, reason: .replacementFailed)
    }

    if await pasteLanded(rewrite, anchor: capture.anchor, before: valueBeforePaste, in: field) {
      saved.restore(to: pasteboard)
      return .pasted
    }
    // The target ignored the paste (read-only, or not accepting input). The
    // rewrite stays on the clipboard so a manual ⌘V can still complete the edit.
    return .leftOnClipboard(.pasteUnverified)
  }

  /// Polls the field for the pasted rewrite. A field that cannot be read back
  /// is trusted, as an accepted accessibility write is.
  private func pasteLanded(
    _ rewrite: String,
    anchor: VoiceEditAnchor,
    before: String?,
    in field: any VoiceEditField
  ) async -> Bool {
    for _ in 0..<pasteVerificationAttempts {
      try? await Task.sleep(for: pasteVerificationInterval)
      guard let value = field.readValue() else { return true }
      if value != before, Self.rewriteShows(rewrite, at: anchor.range, before: before, after: value) {
        return true
      }
    }
    return false
  }

  private static func rewriteShows(
    _ rewrite: String,
    at range: VoiceEditTextRange?,
    before: String?,
    after: String
  ) -> Bool {
    if let range, let before, let expected = replacing(range, in: before, with: rewrite) {
      return after == expected
    }
    return after.contains(rewrite)
  }

  /// `value` with `range` replaced by `replacement`, or nil when the range no
  /// longer fits the value.
  private static func replacing(_ range: VoiceEditTextRange, in value: String, with replacement: String) -> String? {
    guard range.substring(of: value) != nil else { return nil }
    let utf16 = Array(value.utf16)
    let prefix = String(utf16CodeUnits: Array(utf16[0..<range.location]), count: range.location)
    let suffix = String(utf16CodeUnits: Array(utf16[range.end...]), count: utf16.count - range.end)
    return prefix + replacement + suffix
  }

  // MARK: - Clipboard parking

  private func park(_ rewrite: String, reason: VoiceEditClipboardReason) -> Outcome {
    pasteboard.clearContents()
    pasteboard.setString(rewrite, forType: .string)
    return .leftOnClipboard(reason)
  }
}
