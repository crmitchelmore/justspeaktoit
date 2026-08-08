import AppKit
import ApplicationServices
import Foundation
import SpeakCore

/// Captures the text selection in the frontmost app for voice-edit sessions and later replaces
/// it with the LLM rewrite.
///
/// Capture prefers a direct Accessibility read, then a simulated ⌘C into a
/// saved-and-always-restored pasteboard, then the last inserted transcription when it is still
/// present in the focused field. These paths need a real window server, so they are covered by
/// manual testing rather than unit tests.
@MainActor
final class VoiceEditSelectionService {
  struct Capture {
    let selection: VoiceEditOrchestrator.Selection
    let target: TextOutputTarget
  }

  private let permissionsManager: PermissionsManager
  private let appSettings: AppSettings
  private let historyManager: HistoryManager
  private let pasteboard: NSPasteboard

  init(
    permissionsManager: PermissionsManager,
    appSettings: AppSettings,
    historyManager: HistoryManager,
    pasteboard: NSPasteboard = .general
  ) {
    self.permissionsManager = permissionsManager
    self.appSettings = appSettings
    self.historyManager = historyManager
    self.pasteboard = pasteboard
  }

  // MARK: - Capture

  func capture() async -> Capture? {
    let target = TextOutputTarget.capture()
    permissionsManager.refresh(.accessibility)

    if let selected = accessibilitySelectedText(target: target), !selected.isEmpty {
      return Capture(
        selection: .init(text: selected, source: .accessibility),
        target: target
      )
    }
    if let copied = await copySelectionViaClipboard(target: target), !copied.isEmpty {
      return Capture(
        selection: .init(text: copied, source: .clipboard),
        target: target
      )
    }
    if let lastInserted = lastInsertedTranscription(),
       let element = focusedElement(for: target),
       let value = Self.stringAttribute(kAXValueAttribute, of: element),
       (value as NSString).range(of: lastInserted, options: .backwards).location != NSNotFound {
      return Capture(
        selection: .init(text: lastInserted, source: .lastInsertion),
        target: target
      )
    }
    return nil
  }

  private func accessibilitySelectedText(target: TextOutputTarget) -> String? {
    guard permissionsManager.status(for: .accessibility).isGranted,
          let element = focusedElement(for: target)
    else { return nil }
    return Self.stringAttribute(kAXSelectedTextAttribute, of: element)
  }

  /// Copies the current selection by simulating ⌘C. The user's pasteboard contents are saved
  /// first and restored on every exit path, including empty selections and errors.
  private func copySelectionViaClipboard(target: TextOutputTarget) async -> String? {
    guard DistributionChannel.current.supportsAccessibilityTextInsertion else { return nil }
    let saved = savedPasteboardItems()
    defer { restorePasteboard(with: saved) }

    pasteboard.clearContents()
    let baseline = pasteboard.changeCount
    let destination = PasteTextOutput.eventDestination(for: target)
    guard Self.postCopyShortcut(destination: destination) else { return nil }

    // Give the target app a moment to service the copy; bail out early once it lands.
    for _ in 0..<10 where pasteboard.changeCount == baseline {
      try? await Task.sleep(nanoseconds: 40_000_000)
    }
    guard pasteboard.changeCount != baseline else { return nil }
    return pasteboard.string(forType: .string)
  }

  private func lastInsertedTranscription() -> String? {
    let text = historyManager.items.first
      .flatMap { $0.postProcessedTranscription ?? $0.rawTranscription }?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let text, !text.isEmpty else { return nil }
    return text
  }

  // MARK: - Replacement

  func replace(_ capture: Capture, with rewrite: String) -> VoiceEditOrchestrator.ReplacementOutcome {
    if replaceViaAccessibility(capture, rewrite: rewrite) {
      return .replaced
    }
    return pasteReplacement(rewrite, target: capture.target)
  }

  private func replaceViaAccessibility(_ capture: Capture, rewrite: String) -> Bool {
    guard permissionsManager.status(for: .accessibility).isGranted,
          let element = focusedElement(for: capture.target)
    else { return false }

    if capture.selection.source == .lastInsertion {
      guard Self.selectLastOccurrence(of: capture.selection.text, in: element) else {
        return false
      }
    }

    let status = AXUIElementSetAttributeValue(
      element, kAXSelectedTextAttribute as CFString, rewrite as CFTypeRef
    )
    guard status == .success else { return false }
    return Self.verifyRewriteApplied(rewrite, in: element)
  }

  private func pasteReplacement(
    _ rewrite: String,
    target: TextOutputTarget
  ) -> VoiceEditOrchestrator.ReplacementOutcome {
    if DistributionChannel.current.supportsAccessibilityTextInsertion {
      let output = PasteTextOutput(
        permissionsManager: permissionsManager,
        appSettings: appSettings,
        pasteboard: pasteboard
      )
      let result = output.output(text: rewrite, target: target)
      if result.error == nil, result.method == .clipboard {
        return .pasted
      }
    }
    // Mirror the existing delivery fallback: leave the rewrite on the clipboard so a manual
    // ⌘V still completes the edit.
    pasteboard.clearContents()
    pasteboard.setString(rewrite, forType: .string)
    return .leftOnClipboard
  }

  // MARK: - Pasteboard save/restore

  private func savedPasteboardItems() -> [[NSPasteboard.PasteboardType: Data]] {
    let items = pasteboard.pasteboardItems ?? []
    return items.compactMap { item in
      var contents: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types {
        if let data = item.data(forType: type) {
          contents[type] = data
        }
      }
      return contents.isEmpty ? nil : contents
    }
  }

  private func restorePasteboard(with saved: [[NSPasteboard.PasteboardType: Data]]) {
    pasteboard.clearContents()
    let items = saved.map { contents -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in contents {
        item.setData(data, forType: type)
      }
      return item
    }
    if !items.isEmpty {
      pasteboard.writeObjects(items)
    }
  }

  // MARK: - Copy shortcut simulation

  private static func postCopyShortcut(destination: PasteTextOutput.EventDestination) -> Bool {
    guard destination != .none,
          let source = CGEventSource(stateID: .combinedSessionState),
          let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
    else { return false }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    post(keyDown, destination: destination)
    post(keyUp, destination: destination)
    return true
  }

  private static func post(_ event: CGEvent, destination: PasteTextOutput.EventDestination) {
    switch destination {
    case .process(let processIdentifier):
      event.postToPid(processIdentifier)
    case .system:
      event.post(tap: .cghidEventTap)
    case .none:
      break
    }
  }

  // MARK: - Accessibility helpers

  private func focusedElement(for target: TextOutputTarget) -> AXUIElement? {
    target.focusedElement ?? Self.systemFocusedElement()
  }

  private static func systemFocusedElement() -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    var rawFocused: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
      systemWide, kAXFocusedUIElementAttribute as CFString, &rawFocused
    )
    guard status == .success, let rawFocused else { return nil }
    return unsafeBitCast(rawFocused, to: AXUIElement.self)
  }

  private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard status == .success else { return nil }
    return value as? String
  }

  private static func selectLastOccurrence(of text: String, in element: AXUIElement) -> Bool {
    guard let current = stringAttribute(kAXValueAttribute, of: element) else { return false }
    let nsRange = (current as NSString).range(of: text, options: .backwards)
    guard nsRange.location != NSNotFound else { return false }
    var cfRange = CFRange(location: nsRange.location, length: nsRange.length)
    guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return false }
    let status = AXUIElementSetAttributeValue(
      element, kAXSelectedTextRangeAttribute as CFString, axRange
    )
    return status == .success
  }

  /// Re-reads the field after a short delay to confirm the rewrite landed. Fields whose value
  /// cannot be read back (web areas, custom views) are trusted after a successful set call,
  /// because pasting on top of an already-applied rewrite would duplicate it.
  private static func verifyRewriteApplied(_ rewrite: String, in element: AXUIElement) -> Bool {
    Thread.sleep(forTimeInterval: 0.05)
    guard let current = stringAttribute(kAXValueAttribute, of: element) else { return true }
    return current.contains(rewrite)
  }
}
