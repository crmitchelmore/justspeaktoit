import AppKit
import ApplicationServices
import Foundation
import SpeakCore
import os.log

private let logger = SpeakLogger.logger(category: "TextOutput")

/// Pastes through the clipboard with a synthesised Command+V, then restores
/// the previous clipboard unless the user keeps transcripts on it.
@MainActor
struct PasteTextOutput: TextOutputting {
  enum EventDestination: Equatable {
    case process(pid_t)
    case system
    case none
  }

  let permissionsManager: PermissionsManager
  let appSettings: AppSettings
  private let pasteboard: NSPasteboard

  init(
    permissionsManager: PermissionsManager,
    appSettings: AppSettings,
    pasteboard: NSPasteboard = .general
  ) {
    self.permissionsManager = permissionsManager
    self.appSettings = appSettings
    self.pasteboard = pasteboard
  }

  func output(text: String, target: TextOutputTarget?) -> TextOutputResult {
    guard Self.hasDeliverableText(text) else {
      return TextOutputResult(method: .none, error: nil)
    }

    let canPasteIntoOtherApps = DistributionChannel.current.supportsAccessibilityTextInsertion
    let restoreClipboard = canPasteIntoOtherApps && appSettings.restoreClipboardAfterPaste
    // Every item and type, not just the string: an image, file or rich-only
    // clipboard must survive the temporary paste intact (issue #673).
    let previousContents = restoreClipboard ? PasteboardSnapshot(reading: pasteboard) : nil

    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      return TextOutputResult(method: .none, error: TextOutputError.clipboardWriteFailed)
    }

    var insertedRange: VoiceEditTextRange?
    var deliveryWarning: Error?
    if canPasteIntoOtherApps {
      let destination = Self.eventDestination(for: target)
      guard destination != .none else {
        return TextOutputResult(
          method: .clipboard,
          error: TextOutputError.targetApplicationUnavailable
        )
      }
      // PID-directed events reach the captured *process*, not the captured
      // *field*: focus moved to another field in the same app (a different
      // Slack conversation, say) may receive the paste. Surface that as a
      // warning, but honour the user's preference to deliver anyway.
      if let target, let identityError = fieldIdentityError(for: target) {
        deliveryWarning = identityError
        let warningDescription = identityError.localizedDescription
        logger.warning(
          "Output target changed; continuing paste into captured process: \(warningDescription, privacy: .public)"
        )
      }
      // Read before the paste replaces the selection; the pasted text starts
      // where the selection started.
      if deliveryWarning == nil {
        insertedRange = pasteLandingRange(in: target, for: text)
      }
      // The transcript is already on the clipboard and no restore is
      // scheduled, so failing closed here leaves it there.
      if let changed = target?.destinationChangedError() {
        return TextOutputResult(method: .clipboard, error: changed)
      }
      guard simulatePasteShortcut(destination: destination) else {
        return TextOutputResult(method: .clipboard, error: TextOutputError.pasteShortcutUnavailable)
      }
    }

    if let previousContents {
      scheduleClipboardRestore(previousContents, on: pasteboard)
    }

    return TextOutputResult(
      method: .clipboard,
      error: nil,
      warning: deliveryWarning,
      insertedRange: insertedRange
    )
  }

  /// Where `text` will land in the captured field, when Accessibility lets us
  /// read the current selection. Nil when unknown; consumers verify the text
  /// at the range before trusting it.
  private func pasteLandingRange(in target: TextOutputTarget?, for text: String) -> VoiceEditTextRange? {
    guard let element = target?.focusedElement,
      permissionsManager.status(for: .accessibility).isGranted,
      let selection = AccessibilityStreamingTextField(element: element).readSelectedRange()
    else { return nil }
    return VoiceEditTextRange(location: selection.location, length: text.utf16.count)
  }

  static func hasDeliverableText(_ text: String) -> Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func requiresExactFieldIdentity(
    textOutputMethod: AppSettings.TextOutputMethod,
    accessibilityGranted: Bool
  ) -> Bool {
    textOutputMethod != .clipboardOnly && accessibilityGranted
  }

  /// Enforces exact field identity for Smart-mode fallback when Accessibility
  /// is available. Explicit Clipboard mode intentionally uses process-level
  /// identity, as does any installation without Accessibility permission.
  /// Both cases retain the legacy Command-V workflow while refusing to paste
  /// after the user switches to another application.
  private func fieldIdentityError(for target: TextOutputTarget) -> TextOutputError? {
    permissionsManager.refresh(.accessibility)
    let accessibilityGranted = permissionsManager.status(for: .accessibility).isGranted
    guard Self.requiresExactFieldIdentity(
      textOutputMethod: appSettings.textOutputMethod,
      accessibilityGranted: accessibilityGranted
    ) else {
      return target.capturedApplicationIsFrontmost() ? nil : .capturedFieldChanged
    }
    return Self.fieldIdentityError(
      confirmation: target.confirmCapturedFieldOwnsFocus(),
      capturedApplicationIsFrontmost: target.capturedApplicationIsFrontmost()
    )
  }

  static func fieldIdentityError(
    confirmation: TextOutputTarget.CapturedFieldConfirmation,
    capturedApplicationIsFrontmost: Bool
  ) -> TextOutputError? {
    switch confirmation {
    case .confirmed:
      return nil
    case .fieldUnavailable:
      // Some apps do not expose a focused AX element even though the user has
      // granted Accessibility permission. Treat that the same as Clipboard
      // mode: continue only while the captured app is still frontmost. A
      // positive field mismatch remains fail-closed below.
      return capturedApplicationIsFrontmost ? nil : .capturedFieldChanged
    case .fieldChanged:
      return .capturedFieldChanged
    }
  }

  private func simulatePasteShortcut(destination: EventDestination) -> Bool {
    guard
      let source = CGEventSource(stateID: .combinedSessionState),
      let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    else {
      return false
    }

    keyDown.flags = .maskCommand
    post(keyDown, destination: destination)
    keyUp.flags = .maskCommand
    post(keyUp, destination: destination)
    return true
  }

  private func post(_ event: CGEvent, destination: EventDestination) {
    switch destination {
    case .process(let processIdentifier):
      event.postToPid(processIdentifier)
    case .system:
      event.post(tap: .cghidEventTap)
    case .none:
      break
    }
  }

  static func eventDestination(for target: TextOutputTarget?) -> EventDestination {
    guard let target else { return .system }
    guard target.isApplicationRunning, let processIdentifier = target.processIdentifier else {
      return .none
    }
    return .process(processIdentifier)
  }

  private func scheduleClipboardRestore(_ previousContents: PasteboardSnapshot, on pasteboard: NSPasteboard) {
    let delay = DispatchTime.now() + .milliseconds(300)
    DispatchQueue.main.asyncAfter(deadline: delay) {
      previousContents.restore(to: pasteboard)
    }
  }
}
