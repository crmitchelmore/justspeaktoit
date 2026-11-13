import AppKit
import ApplicationServices
import Foundation
import SpeakCore
import os.log

private let logger = SpeakLogger.logger(category: "LiveTextInserter")

/// The default live insertion strategy: rewrites the captured field's whole
/// value through `kAXValueAttribute` on every update.
@MainActor
final class FullValueInserter: LiveInsertionWriter {
  private(set) var insertedText = ""
  private(set) var insertedRange: VoiceEditTextRange?
  private var firstInsertionVerified = false
  private weak var host: LiveInsertionHost?

  init(host: LiveInsertionHost) {
    self.host = host
  }

  func update(with newText: String) {
    if newText.count < insertedText.count {
      // Text got shorter - likely a correction. Replace entire text.
      replaceInsertedText(with: newText)
    } else if newText.hasPrefix(insertedText) {
      // New text extends what we have - append the delta
      let delta = String(newText.dropFirst(insertedText.count))
      if !delta.isEmpty {
        appendText(delta)
      }
    } else {
      // Text changed substantially - replace
      replaceInsertedText(with: newText)
    }
  }

  func finalize(with finalText: String) -> LiveTextInserter.FinalizationResult {
    // Nothing was inserted live, just do normal insertion
    insertedText.isEmpty ? insertFresh(finalText) : replaceInsertedText(with: finalText)
  }

  /// Whole-value rewrites keep no pre-session baseline, so there is no way to
  /// prove the field holds only this session's change; the text stays.
  func rollBack() -> LiveTextInserter.RollbackResult {
    insertedText.isEmpty
      ? .nothingInserted
      : .kept(reason: "full-value live insertion cannot verify the region to remove")
  }

  private func appendText(_ text: String) {
    guard let host else { return }
    guard let focusedElement = host.focusedTextElement() else {
      host.deferToStandardDelivery(
        reason: "appendText failed: no focused element",
        error: TextOutputError.unableToFindFocusedElement,
        textAbsentFromField: false
      )
      return
    }

    let newValue = (Self.readValue(of: focusedElement) ?? insertedText) + text
    guard host.capturedTargetAllowsWrite() else { return }
    let setResult = AXUIElementSetAttributeValue(
      focusedElement, kAXValueAttribute as CFString, newValue as CFTypeRef
    )
    guard setResult == .success else {
      host.deferToStandardDelivery(
        reason: "appendText failed with AXError: \(setResult.rawValue)",
        error: TextOutputError.unableToSetValue(setResult),
        textAbsentFromField: false
      )
      return
    }
    host.recordAccessibilityWrite()

    // Verify first insertion to ensure accessibility is actually working
    if !firstInsertionVerified {
      if verifyInsertion(expected: newValue, element: focusedElement) {
        firstInsertionVerified = true
        logger.debug("First insertion verified successfully")
      } else {
        insertedText = newValue
        host.recordError(TextOutputError.unableToVerifyInsertion)
        host.pauseIncrementalUpdates(reason: "First insertion verification failed")
        return
      }
    }

    insertedText += text
    logger.debug("Appended \(text.count) chars, total: \(self.insertedText.count)")
  }

  @discardableResult
  private func replaceInsertedText(with newText: String) -> LiveTextInserter.FinalizationResult {
    guard let host else { return .deferred }
    guard let focusedElement = host.focusedTextElement() else {
      return deferAfterFailure(
        reason: "replaceInsertedText failed: no focused element",
        error: TextOutputError.unableToFindFocusedElement,
        host: host
      )
    }

    var finalValue: String
    // UTF-16 offset where `newText` starts in `finalValue`, when known.
    var insertedLocation: Int?
    if let current = Self.readValue(of: focusedElement) {
      // Remove what we previously inserted, add the new text
      if current.hasSuffix(insertedText) && !insertedText.isEmpty {
        let prefix = String(current.dropLast(insertedText.count))
        finalValue = prefix + newText
        insertedLocation = prefix.utf16.count
      } else {
        // Can't find our inserted text - just append
        finalValue = current.isEmpty ? newText : current
        insertedLocation = current.isEmpty ? 0 : nil
      }
    } else {
      finalValue = newText
      insertedLocation = 0
    }

    guard host.capturedTargetAllowsWrite() else { return .deferred }
    let setResult = AXUIElementSetAttributeValue(
      focusedElement, kAXValueAttribute as CFString, finalValue as CFTypeRef
    )
    guard setResult == .success else {
      return deferAfterFailure(
        reason: "replaceInsertedText failed with AXError: \(setResult.rawValue)",
        error: TextOutputError.unableToSetValue(setResult),
        host: host
      )
    }
    host.recordAccessibilityWrite()
    insertedText = newText
    insertedRange = insertedLocation.map {
      VoiceEditTextRange(location: $0, length: newText.utf16.count)
    }
    return .applied
  }

  private func insertFresh(_ text: String) -> LiveTextInserter.FinalizationResult {
    guard let host else { return .deferred }
    guard let focusedElement = host.focusedTextElement() else {
      return deferAfterFailure(
        reason: "insertFresh failed: no focused element",
        error: TextOutputError.unableToFindFocusedElement,
        host: host
      )
    }

    let newValue = (Self.readValue(of: focusedElement) ?? "") + text
    guard host.capturedTargetAllowsWrite() else { return .deferred }
    let setResult = AXUIElementSetAttributeValue(
      focusedElement, kAXValueAttribute as CFString, newValue as CFTypeRef
    )
    guard setResult == .success else {
      return deferAfterFailure(
        reason: "insertFresh failed with AXError: \(setResult.rawValue)",
        error: TextOutputError.unableToSetValue(setResult),
        host: host
      )
    }
    host.recordAccessibilityWrite()
    insertedText = text
    insertedRange = VoiceEditTextRange(
      location: newValue.utf16.count - text.utf16.count,
      length: text.utf16.count
    )
    return .applied
  }

  /// Defers to standard delivery when nothing landed yet; otherwise the
  /// failure stands, because a second delivery would duplicate the text.
  private func deferAfterFailure(
    reason: String,
    error: TextOutputError,
    host: LiveInsertionHost
  ) -> LiveTextInserter.FinalizationResult {
    host.deferToStandardDelivery(reason: reason, error: error, textAbsentFromField: false)
    return host.usingClipboardFallback ? .deferred : .failed(host.lastError ?? error)
  }

  private static func readValue(of element: AXUIElement) -> String? {
    var currentValue: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValue)
    guard status == .success else { return nil }
    return currentValue as? String
  }

  /// Verify that text was actually inserted by re-reading the value after a short delay.
  /// Runs on MainActor, so it must avoid semaphore + Task patterns that can deadlock.
  private func verifyInsertion(expected: String, element: AXUIElement) -> Bool {
    // Give the target app a brief moment to apply the AX value change before re-reading it.
    // This synchronous wait avoids the MainActor deadlock caused by waiting on a semaphore
    // while also scheduling the verification work back onto MainActor.
    Thread.sleep(forTimeInterval: 0.05)
    guard let currentString = Self.readValue(of: element) else { return false }
    return currentString == expected || currentString.hasSuffix(expected)
  }
}
