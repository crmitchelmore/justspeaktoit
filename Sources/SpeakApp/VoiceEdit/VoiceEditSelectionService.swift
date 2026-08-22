import AppKit
import ApplicationServices
import Foundation
import SpeakCore

/// Captures the text selection in the frontmost app for voice-edit sessions,
/// together with an anchor the replacement step re-verifies before writing.
///
/// Capture prefers a direct Accessibility read (which also yields the selected
/// range), then a simulated ⌘C into a saved-and-always-restored pasteboard,
/// then the exact range where the last dictation was inserted. Field access,
/// the frontmost target, and the copy shortcut are injectable so every path is
/// unit-testable without a window server (issue #673).
@MainActor
final class VoiceEditSelectionService {
  struct Capture {
    let selection: VoiceEditOrchestrator.Selection
    let target: TextOutputTarget
    /// The field that held the selection, when Accessibility could resolve it.
    let field: (any VoiceEditField)?
    let anchor: VoiceEditAnchor
  }

  typealias CopyShortcut = @MainActor (PasteTextOutput.EventDestination) -> Bool

  private let permissionsManager: PermissionsManager
  private let insertionRecords: InsertionRecordStore
  private let fieldResolver: any VoiceEditFieldResolving
  private let pasteboard: NSPasteboard
  private let targetProvider: @MainActor () -> TextOutputTarget
  private let copyShortcut: CopyShortcut
  private let copySettleDelay: Duration

  init(
    permissionsManager: PermissionsManager,
    insertionRecords: InsertionRecordStore,
    fieldResolver: any VoiceEditFieldResolving = AccessibilityVoiceEditFieldResolver(),
    pasteboard: NSPasteboard = .general,
    targetProvider: @escaping @MainActor () -> TextOutputTarget = { TextOutputTarget.capture() },
    copyShortcut: @escaping CopyShortcut = VoiceEditKeyboardShortcuts.postCopy,
    copySettleDelay: Duration = .milliseconds(40)
  ) {
    self.permissionsManager = permissionsManager
    self.insertionRecords = insertionRecords
    self.fieldResolver = fieldResolver
    self.pasteboard = pasteboard
    self.targetProvider = targetProvider
    self.copyShortcut = copyShortcut
    self.copySettleDelay = copySettleDelay
  }

  func capture() async -> Capture? {
    let target = targetProvider()
    permissionsManager.refresh(.accessibility)
    let field = permissionsManager.status(for: .accessibility).isGranted
      ? fieldResolver.field(for: target)
      : nil

    if let field, let selected = field.readSelectedText(), !selected.isEmpty {
      return Capture(
        selection: .init(text: selected, source: .accessibility),
        target: target,
        field: field,
        anchor: VoiceEditAnchor(text: selected, range: Self.verifiedSelectionRange(for: selected, in: field))
      )
    }
    if let copied = await copySelectionViaClipboard(target: target), !copied.isEmpty {
      return Capture(
        selection: .init(text: copied, source: .clipboard),
        target: target,
        field: field,
        anchor: VoiceEditAnchor(
          text: copied,
          range: field.flatMap { Self.verifiedSelectionRange(for: copied, in: $0) }
        )
      )
    }
    if let record = insertionRecords.latest, let capture = lastInsertionCapture(record, target: target) {
      return capture
    }
    return nil
  }

  /// The current selected range, but only when it provably covers `text`.
  /// A range that disagrees with the field's value is not an anchor.
  private static func verifiedSelectionRange(
    for text: String,
    in field: any VoiceEditField
  ) -> VoiceEditTextRange? {
    guard let selection = field.readSelectedRange() else { return nil }
    let range = VoiceEditTextRange(selection)
    guard let value = field.readValue() else { return range }
    return range.substring(of: value) == text ? range : nil
  }

  /// The last dictation is editable only where it actually landed: the same
  /// app, the same field, and the recorded range still holding the recorded
  /// text. No text search, so identical text elsewhere is never picked.
  private func lastInsertionCapture(_ record: InsertionRecord, target: TextOutputTarget) -> Capture? {
    guard record.target.isApplicationRunning,
      record.target.processIdentifier == target.processIdentifier,
      permissionsManager.status(for: .accessibility).isGranted,
      let recordedField = fieldResolver.field(for: record.target),
      let focused = fieldResolver.focusedField(),
      focused.isSameField(as: recordedField),
      let value = recordedField.readValue(),
      record.range.substring(of: value) == record.text
    else { return nil }
    return Capture(
      selection: .init(text: record.text, source: .lastInsertion),
      target: target,
      field: recordedField,
      anchor: VoiceEditAnchor(text: record.text, range: record.range)
    )
  }

  /// Copies the current selection by simulating ⌘C. The user's pasteboard
  /// contents — every item and type — are saved first and restored on every
  /// exit path, including empty selections and errors.
  private func copySelectionViaClipboard(target: TextOutputTarget) async -> String? {
    guard DistributionChannel.current.supportsAccessibilityTextInsertion else { return nil }
    let saved = PasteboardSnapshot(reading: pasteboard)
    defer { saved.restore(to: pasteboard) }

    pasteboard.clearContents()
    let baseline = pasteboard.changeCount
    let destination = PasteTextOutput.eventDestination(for: target)
    guard copyShortcut(destination) else { return nil }

    // Give the target app a moment to service the copy; bail out early once it lands.
    for _ in 0..<10 {
      guard pasteboard.changeCount == baseline else { break }
      try? await Task.sleep(for: copySettleDelay)
    }
    guard pasteboard.changeCount != baseline else { return nil }
    return pasteboard.string(forType: .string)
  }
}

/// Simulated ⌘C / ⌘V delivery to a target process.
enum VoiceEditKeyboardShortcuts {
  private static let copyKeyCode: CGKeyCode = 8
  private static let pasteKeyCode: CGKeyCode = 9

  @MainActor
  static func postCopy(to destination: PasteTextOutput.EventDestination) -> Bool {
    post(keyCode: copyKeyCode, destination: destination)
  }

  @MainActor
  static func postPaste(to destination: PasteTextOutput.EventDestination) -> Bool {
    post(keyCode: pasteKeyCode, destination: destination)
  }

  private static func post(keyCode: CGKeyCode, destination: PasteTextOutput.EventDestination) -> Bool {
    guard destination != .none,
      let source = CGEventSource(stateID: .combinedSessionState),
      let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    else { return false }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    deliver(keyDown, to: destination)
    deliver(keyUp, to: destination)
    return true
  }

  private static func deliver(_ event: CGEvent, to destination: PasteTextOutput.EventDestination) {
    switch destination {
    case .process(let processIdentifier):
      event.postToPid(processIdentifier)
    case .system:
      event.post(tap: .cghidEventTap)
    case .none:
      break
    }
  }
}
