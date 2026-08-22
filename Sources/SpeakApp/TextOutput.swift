/* @Context # Smart Text Insertion Implementation Blueprint

This guide explains how to integrate an "Insert" action that prefers Accessibility value injection and automatically falls back to a Command+V paste. Follow the steps in order; each section points to the relevant code inside this project so a junior engineer can reproduce the behaviour in another app.

## 1. Extend the Text Injector Facade

### 1.1 Define a Result Payload
- File: `Sources/PasteDelayApp/TextInjector.swift:12`
- Add `TextInjector.Result` with two stored properties:
  - `method: Method` tracks which delivery path succeeded.
  - `fallbackReason: InjectionError?` captures (optional) context when the pasteboard fallback runs.
- Implement a `successMessage` computed property that renders user-facing status text depending on the path used. Keep pasteboard-fallback messaging explicit: `Sent text using Command+V fallback (<reason>).`

### 1.2 Enrich InjectionError
- File: `Sources/PasteDelayApp/TextInjector.swift:29`
- Ensure `InjectionError` covers `emptyPayload`, `accessibilityDenied`, `noFocusedElement`, and `valueNotSettable`.
// @Implement: This implementation should use the clipboard to paste text into the focused app. It should restore the previous pasteboard value (if the app setting output to clipboard is false) It should respect any relevant settings from app settings
// swiftlint:disable file_length
import AppKit
import ApplicationServices
import Foundation
- Restore the clipboard after pasteboard-based injection to avoid surprising users.
- Document fallback behaviour prominently in user-facing copy so expectations stay aligned.

Following this sequence allows another project to drop in the same smart Insert capability with minimal guesswork.
 */

// swiftlint:disable file_length
import AppKit
import ApplicationServices
import Foundation
import SpeakCore
import os.log

private let logger = SpeakLogger.logger(category: "TextOutput")

struct TextOutputResult {
  let method: HistoryTrigger.OutputMethod
  let error: Error?
  /// Where the text landed in the focused field, when the delivery path can
  /// tell. Voice Edit's "last dictation" fallback edits this exact range
  /// (issue #673).
  let insertedRange: VoiceEditTextRange?

  init(
    method: HistoryTrigger.OutputMethod,
    error: Error?,
    insertedRange: VoiceEditTextRange? = nil
  ) {
    self.method = method
    self.error = error
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

/// The app and text control that owned keyboard focus when a transcription session began.
/// Keeping this target avoids delivering into an unrelated app if focus changes while the
/// recording is transcribed or post-processed.
struct TextOutputTarget {
  let processIdentifier: pid_t?
  let applicationName: String?
  let bundleIdentifier: String?
  let applicationLaunchDate: Date?
  let focusedElement: AXUIElement?

  static func capture() -> TextOutputTarget {
    let application = NSWorkspace.shared.frontmostApplication
    guard DistributionChannel.current.supportsAccessibilityTextInsertion else {
      return TextOutputTarget(
        processIdentifier: application?.processIdentifier,
        applicationName: application?.localizedName,
        bundleIdentifier: application?.bundleIdentifier,
        applicationLaunchDate: application?.launchDate,
        focusedElement: nil
      )
    }
    return TextOutputTarget(
      processIdentifier: application?.processIdentifier,
      applicationName: application?.localizedName,
      bundleIdentifier: application?.bundleIdentifier,
      applicationLaunchDate: application?.launchDate,
      focusedElement: currentSystemFocusedElement()
    )
  }

  var isApplicationRunning: Bool {
    guard
      let processIdentifier,
      let application = NSRunningApplication(processIdentifier: processIdentifier),
      !application.isTerminated
    else {
      return false
    }
    if let bundleIdentifier, application.bundleIdentifier != bundleIdentifier {
      return false
    }
    if let applicationLaunchDate, application.launchDate != applicationLaunchDate {
      return false
    }
    return true
  }

  /// Whether the captured AX element belongs to the captured process. An
  /// AXUIElement is bound to one process for its lifetime, so a mismatch means
  /// the capture raced an app switch and the element must not be used
  /// (issue #707).
  func capturedElementBelongsToCapturedProcess() -> Bool {
    guard let focusedElement, let processIdentifier else { return false }
    var elementProcessIdentifier: pid_t = 0
    guard AXUIElementGetPid(focusedElement, &elementProcessIdentifier) == .success else {
      return false
    }
    return elementProcessIdentifier == processIdentifier
  }

  /// Field-identity confirmation for keystroke-based delivery (issue #707).
  enum CapturedFieldConfirmation: Equatable {
    /// The captured field is the captured process's current focus.
    case confirmed
    /// No AX element was captured, so field identity cannot be proven.
    case fieldUnavailable
    /// The captured process is not frontmost, or focus moved to a different
    /// field (for example another conversation in the same app).
    case fieldChanged
  }

  /// Confirms that a simulated paste would land in the captured field: the
  /// captured process must be frontmost and its current focused element must
  /// be the captured element. PID-directed events reach a process, not a
  /// field, so without this proof a paste can land in whichever field owns
  /// focus now (issue #707).
  func confirmCapturedFieldOwnsFocus(
    frontmostProcessIdentifier: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier,
    currentFocus: () -> AXUIElement? = currentSystemFocusedElement
  ) -> CapturedFieldConfirmation {
    guard let focusedElement else { return .fieldUnavailable }
    guard capturedElementBelongsToCapturedProcess(),
          let frontmostProcessIdentifier,
          frontmostProcessIdentifier == processIdentifier,
          let current = currentFocus(),
          CFEqual(current, focusedElement)
    else {
      return .fieldChanged
    }
    return .confirmed
  }
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
    }
  }
}

// @Implement: This implementation should check for accessibility permissions and use the accessibility API to paste text into the focused app. It should respect any relevant settings from app settings
@MainActor
struct AccessibilityTextOutput: TextOutputting {
  let permissionsManager: PermissionsManager
  let appSettings: AppSettings

  func output(text: String, target: TextOutputTarget?) -> TextOutputResult {
    permissionsManager.refresh(.accessibility)
    let status = permissionsManager.status(for: .accessibility)
    guard status.isGranted else {
      return TextOutputResult(
        method: .none,
        error: TextOutputError.accessibilityPermissionMissing
      )
    }

    if let target, !target.isApplicationRunning {
      return TextOutputResult(
        method: .none,
        error: TextOutputError.targetApplicationUnavailable
      )
    }

    let focusedElement: AXUIElement
    switch Self.resolveDeliveryElement(for: target) {
    case .success(let element):
      focusedElement = element
    case .failure(let error):
      return TextOutputResult(method: .none, error: error)
    }

    switch appSettings.accessibilityInsertionMode {
    case .insertAtCursor:
      return insertAtCursor(text, into: focusedElement)

    case .replaceAll:
      let setResult = AXUIElementSetAttributeValue(
        focusedElement, kAXValueAttribute as CFString, text as CFTypeRef)
      guard setResult == .success else {
        return TextOutputResult(
          method: .none,
          error: TextOutputError.unableToSetValue(setResult)
        )
      }
      return TextOutputResult(
        method: .accessibility,
        error: nil,
        insertedRange: VoiceEditTextRange(location: 0, length: text.utf16.count)
      )
    }
  }

  /// Replaces the current selection (or inserts at the caret), falling back to
  /// replacing the whole field when the app rejects selected-text insertion.
  private func insertAtCursor(_ text: String, into focusedElement: AXUIElement) -> TextOutputResult {
    // The selection about to be replaced tells us where the text will land.
    let selectionBeforeInsert = AccessibilityStreamingTextField(element: focusedElement)
      .readSelectedRange()
    let setResult = AXUIElementSetAttributeValue(
      focusedElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
    guard setResult == .success else {
      let fallbackResult = AXUIElementSetAttributeValue(
        focusedElement, kAXValueAttribute as CFString, text as CFTypeRef)
      guard fallbackResult == .success else {
        return TextOutputResult(
          method: .none,
          error: TextOutputError.unableToSetValue(fallbackResult)
        )
      }
      return TextOutputResult(
        method: .accessibility,
        error: nil,
        insertedRange: VoiceEditTextRange(location: 0, length: text.utf16.count)
      )
    }
    return TextOutputResult(
      method: .accessibility,
      error: nil,
      insertedRange: selectionBeforeInsert.map {
        VoiceEditTextRange(location: $0.location, length: text.utf16.count)
      }
    )
  }

  /// A non-nil target is a captured-field contract: when its AX element is
  /// missing (capture failed) or belongs to another process (the capture
  /// raced an app switch), never resolve the *current* focus in its place —
  /// that is how a transcript lands in an unrelated app (issue #707).
  /// `target == nil` remains the explicit current-focus operation.
  static func resolveDeliveryElement(
    for target: TextOutputTarget?
  ) -> Result<AXUIElement, TextOutputError> {
    if let target {
      guard let captured = target.focusedElement else {
        return .failure(.capturedFieldUnavailable)
      }
      guard target.capturedElementBelongsToCapturedProcess() else {
        return .failure(.capturedFieldChanged)
      }
      return .success(captured)
    }
    guard let current = currentSystemFocusedElement() else {
      return .failure(.unableToFindFocusedElement)
    }
    return .success(current)
  }
}

// @Implement: This implementation should use the clipboard to paste text into the focused app. It should restore the previous pasteboard value (if the app setting output to clipboard is false) It should respect any relevant settings from app settings
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
      // Slack conversation, say) would receive the paste. Withhold the
      // keystroke unless the captured field provably still owns focus; the
      // transcript stays on the clipboard with the reason (issue #707).
      if let target {
        switch target.confirmCapturedFieldOwnsFocus() {
        case .confirmed:
          break
        case .fieldUnavailable:
          return TextOutputResult(
            method: .clipboard,
            error: TextOutputError.capturedFieldUnavailable
          )
        case .fieldChanged:
          return TextOutputResult(
            method: .clipboard,
            error: TextOutputError.capturedFieldChanged
          )
        }
      }
      // Read before the paste replaces the selection; the pasted text starts
      // where the selection started.
      insertedRange = pasteLandingRange(in: target, for: text)
      guard simulatePasteShortcut(destination: destination) else {
        return TextOutputResult(method: .clipboard, error: TextOutputError.pasteShortcutUnavailable)
      }
    }

    if let previousContents {
      scheduleClipboardRestore(previousContents, on: pasteboard)
    }

    return TextOutputResult(method: .clipboard, error: nil, insertedRange: insertedRange)
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

// @Implement: Smart text output that uses accessibility when permitted and falls back to clipboard.
@MainActor
struct SmartTextOutput: TextOutputting {
  let permissionsManager: PermissionsManager
  let appSettings: AppSettings

  /// Apps known to not support accessibility text insertion properly.
  /// These apps will always use clipboard fallback when in "smart" mode.
  private static let problematicApps: Set<String> = [
    // Chromium-based browsers
    "Google Chrome",
    "Google Chrome Canary",
    "Chromium",
    "Microsoft Edge",
    "Brave Browser",
    "Opera",
    "Vivaldi",
    "Arc",
    // Electron apps
    "Slack",
    "Discord",
    "Visual Studio Code",
    "VS Code",
    "Code",
    "Cursor",
    "Atom",
    "Notion",
    "Figma",
    "Obsidian",
    "Postman",
    "Insomnia",
    "GitHub Desktop",
    "Hyper",
    "Terminus",
    "1Password",
    "Bitwarden",
    "Spotify",
    "Teams",
    "Microsoft Teams",
    "Zoom",
    "Webex",
    // Other apps with known issues
    "Microsoft Word",
    "Microsoft Excel",
    "Microsoft PowerPoint",
    "Firefox",
    "iTerm2",
    "iTerm",
    "Alacritty",
    "kitty",
    "Warp",
    "Terminal" // Some secure input issues
  ]

  private var accessibilityOutput: AccessibilityTextOutput {
    AccessibilityTextOutput(permissionsManager: permissionsManager, appSettings: appSettings)
  }

  private var clipboardOutput: PasteTextOutput {
    PasteTextOutput(permissionsManager: permissionsManager, appSettings: appSettings)
  }

  func output(text: String, target: TextOutputTarget?) -> TextOutputResult {
    guard DistributionChannel.current.supportsAccessibilityTextInsertion else {
      return clipboardOutput.output(text: text, target: target)
    }

    switch appSettings.textOutputMethod {
    case .accessibilityOnly:
      return accessibilityOutput.output(text: text, target: target)
    case .clipboardOnly:
      return clipboardOutput.output(text: text, target: target)
    case .smart:
      if let target, !target.isApplicationRunning {
        return clipboardOutput.output(text: text, target: target)
      }
      // Skip accessibility for known problematic apps
      if isProblematic(target: target) {
        logger.info("Skipping accessibility for problematic app, using clipboard")
        return clipboardOutput.output(text: text, target: target)
      }

      // Permission grants can change while System Settings is frontmost. Re-read
      // TCC before deciding whether direct insertion is available.
      permissionsManager.refresh(.accessibility)

      // Only try accessibility if permission is granted AND the captured
      // field (or, with no target, current focus) resolved. A missing or
      // cross-process captured element falls through to the clipboard path,
      // whose own field-identity gate decides about the paste keystroke —
      // never to current focus (issue #707).
      if permissionsManager.status(for: .accessibility).isGranted,
         case .success(let focusedElement) = AccessibilityTextOutput.resolveDeliveryElement(for: target) {

        // Log element info for debugging
        logFocusedElementInfo(focusedElement)

        // Check if the attribute is settable
        var settable: DarwinBoolean = false
        let isSettable = AXUIElementIsAttributeSettable(
          focusedElement, kAXValueAttribute as CFString, &settable)
        guard isSettable == .success && settable.boolValue else {
          logger.info("Value attribute not settable, falling back to clipboard")
          return clipboardOutput.output(text: text, target: target)
        }

        // Try accessibility insertion
        let result = accessibilityOutput.output(text: text, target: target)
        if result.error == nil {
          // Verify the text was actually inserted by re-reading the value
          if verifyTextInserted(text: text, element: focusedElement) {
            return result
          } else {
            logger.info("Text insertion not verified, falling back to clipboard")
          }
        }
      }
      return clipboardOutput.output(text: text, target: target)
    }
  }

  private func isProblematic(target: TextOutputTarget?) -> Bool {
    let appName = target?.applicationName
      ?? NSWorkspace.shared.frontmostApplication?.localizedName
      ?? ""
    return Self.problematicApps.contains(appName)
  }

  /// Verify that the text was actually inserted into the focused element.
  /// Some apps return success from AXUIElementSetAttributeValue but don't actually update.
  /// Includes a brief spin to allow the target app to process the change.
  private func verifyTextInserted(text: String, element: AXUIElement) -> Bool {
    // Brief pause for the target app to process the accessibility change.
    // Thread.sleep is acceptable here — this is a tiny delay and avoids
    // the deadlock that DispatchSemaphore + MainActor Task would cause.
    Thread.sleep(forTimeInterval: 0.05)

    var currentValue: CFTypeRef?
    let getStatus = AXUIElementCopyAttributeValue(
      element, kAXValueAttribute as CFString, &currentValue)
    if getStatus == .success, let currentString = currentValue as? String {
      // With insert-at-cursor the text could be anywhere in the field
      return currentString.contains(text) || currentString == text
    }
    return false
  }

  /// Log information about the focused element for debugging
  private func logFocusedElementInfo(_ element: AXUIElement) {
    var role: CFTypeRef?
    var roleDesc: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &roleDesc)
    let roleStr = (role as? String) ?? "unknown"
    let roleDescStr = (roleDesc as? String) ?? "unknown"
    logger.debug(
      "Focused element - role: \(roleStr, privacy: .public), description: \(roleDescStr, privacy: .public)")
  }
}
