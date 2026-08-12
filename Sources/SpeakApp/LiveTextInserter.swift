import AppKit
import ApplicationServices
import Foundation
import SpeakCore
import os.log

private let logger = SpeakLogger.logger(category: "LiveTextInserter")

/// Handles live incremental text insertion during streaming transcription.
/// Tracks what's been inserted and handles updates/replacements.
/// Falls back to clipboard mode if accessibility insertion isn't available.
@MainActor
final class LiveTextInserter: ObservableObject { // swiftlint:disable:this type_body_length
  enum FinalizationResult {
    case applied
    case deferred
    case failed(Error)
  }

  /// The text that has been successfully inserted
  @Published private(set) var insertedText: String = ""

  /// Whether live insertion is active
  @Published private(set) var isActive: Bool = false

  /// Whether live insertion should stop and let the standard final-delivery path handle output.
  @Published private(set) var usingClipboardFallback: Bool = false

  /// The last error encountered
  @Published private(set) var lastError: Error?

  private let permissionsManager: PermissionsManager
  private let appSettings: AppSettings

  /// Preserve the exact destination that owned focus when recording began.
  private var target: TextOutputTarget?

  /// Character count we've successfully inserted (for incremental updates)
  private var confirmedCharCount: Int = 0

  /// Whether first insertion was verified successfully
  private var firstInsertionVerified: Bool = false

  /// Whether an accessibility write has already succeeded, even if verification later failed.
  private var hasPerformedAccessibilityWrite: Bool = false

  /// Timestamp of the first successful accessibility write in this session
  /// (latency checkpoint: first character visible in the target app).
  private(set) var firstInsertionAt: Date?

  /// Whether incremental live updates should pause until finalization.
  private var shouldPauseIncrementalUpdates: Bool = false

  var shouldUseLiveFinalization: Bool {
    isActive && !usingClipboardFallback
  }

  init(permissionsManager: PermissionsManager, appSettings: AppSettings) {
    self.permissionsManager = permissionsManager
    self.appSettings = appSettings
  }

  /// Start a live insertion session
  func begin(target: TextOutputTarget? = nil) {
    guard canUseAccessibility() else {
      lastError = TextOutputError.accessibilityPermissionMissing
      logger.error("Cannot start: accessibility permission missing")
      return
    }

    insertedText = ""
    confirmedCharCount = 0
    firstInsertionVerified = false
    hasPerformedAccessibilityWrite = false
    self.firstInsertionAt = nil
    shouldPauseIncrementalUpdates = false
    usingClipboardFallback = false
    isActive = true
    lastError = nil
    self.target = target ?? .capture()
    let targetApp = self.target?.applicationName ?? "unknown"
    logger.info(
      "Started live insertion session, target app: \(targetApp), deferring AX readiness checks"
    )
  }

  /// End the live insertion session
  func end() {
    if isActive {
      logger.info("Ended session, inserted \(self.insertedText.count) characters")
    }
    isActive = false
  }

  /// Reset state for a new session
  func reset() {
    insertedText = ""
    confirmedCharCount = 0
    firstInsertionVerified = false
    hasPerformedAccessibilityWrite = false
    self.firstInsertionAt = nil
    shouldPauseIncrementalUpdates = false
    usingClipboardFallback = false
    isActive = false
    lastError = nil
    target = nil
  }

  /// Update with new transcription text - handles incremental insertion
  /// - Parameter newText: The full current transcript (not just the delta)
  func update(with newText: String) {
    guard isActive else { return }
    guard !usingClipboardFallback else { return }
    guard !shouldPauseIncrementalUpdates else { return }
    guard !newText.isEmpty else { return }

    // Calculate what's new since last confirmed insertion
    let trimmedNew = newText.trimmingCharacters(in: .whitespaces)

    // If the new text is shorter (correction), we need to handle replacement
    if trimmedNew.count < insertedText.count {
      // Text got shorter - likely a correction. Replace entire text.
      replaceInsertedText(with: trimmedNew)
    } else if trimmedNew.hasPrefix(insertedText) {
      // New text extends what we have - append the delta
      let delta = String(trimmedNew.dropFirst(insertedText.count))
      if !delta.isEmpty {
        appendText(delta)
      }
    } else {
      // Text changed substantially - replace
      replaceInsertedText(with: trimmedNew)
    }
  }

  /// Apply final polished text - replaces what was inserted with polished version
  func applyPolishedFinal(_ polishedText: String) -> FinalizationResult {
    guard shouldUseLiveFinalization else { return .deferred }

    guard !insertedText.isEmpty else {
      // Nothing was inserted live, just do normal insertion
      return insertFresh(polishedText)
    }

    // Replace the live-inserted text with the polished version
    return replaceInsertedText(with: polishedText)
  }

  // MARK: - Private Methods

  private func canUseAccessibility() -> Bool {
    let status = permissionsManager.status(for: .accessibility)
    return status.isGranted
  }

  private var canDeferToStandardDelivery: Bool {
    !hasPerformedAccessibilityWrite
  }

  /// Records a successful accessibility write, stamping the first-insert
  /// latency checkpoint the first time text lands in the target app.
  private func recordAccessibilityWrite() {
    hasPerformedAccessibilityWrite = true
    if self.firstInsertionAt == nil {
      self.firstInsertionAt = Date()
    }
  }

  private func deferToStandardDelivery(reason: String, error: Error? = nil) {
    if let error {
      lastError = error
    }

    guard canDeferToStandardDelivery else {
      logger.info("\(reason, privacy: .public)")
      return
    }

    usingClipboardFallback = true
    logger.info("\(reason, privacy: .public), deferring to standard delivery")
  }

  private func appendText(_ text: String) {
    guard let focusedElement = getFocusedTextElement() else {
      deferToStandardDelivery(
        reason: "appendText failed: no focused element",
        error: TextOutputError.unableToFindFocusedElement
      )
      return
    }

    // Get current value
    var currentValue: CFTypeRef?
    let getStatus = AXUIElementCopyAttributeValue(
      focusedElement, kAXValueAttribute as CFString, &currentValue
    )

    var newValue: String
    if getStatus == .success, let current = currentValue as? String {
      newValue = current + text
    } else {
      // No existing value, just set the new text
      newValue = insertedText + text
    }

    let setResult = AXUIElementSetAttributeValue(
      focusedElement, kAXValueAttribute as CFString, newValue as CFTypeRef
    )

    if setResult == .success {
      recordAccessibilityWrite()

      // Verify first insertion to ensure accessibility is actually working
      if !firstInsertionVerified {
        if verifyInsertion(expected: newValue, element: focusedElement) {
          firstInsertionVerified = true
          logger.debug("First insertion verified successfully")
        } else {
          insertedText = newValue
          confirmedCharCount = insertedText.count
          shouldPauseIncrementalUpdates = true
          lastError = TextOutputError.unableToVerifyInsertion
          logger.warning("First insertion verification failed, pausing incremental updates")
          return
        }
      }

      insertedText += text
      confirmedCharCount = insertedText.count
      logger.debug("Appended \(text.count) chars, total: \(self.insertedText.count)")
    } else {
      deferToStandardDelivery(
        reason: "appendText failed with AXError: \(setResult.rawValue)",
        error: TextOutputError.unableToSetValue(setResult)
      )
    }
  }

  private func replaceInsertedText(with newText: String) -> FinalizationResult {
    guard let focusedElement = getFocusedTextElement() else {
      deferToStandardDelivery(
        reason: "replaceInsertedText failed: no focused element",
        error: TextOutputError.unableToFindFocusedElement
      )
      return usingClipboardFallback ? .deferred : .failed(lastError ?? TextOutputError.unableToFindFocusedElement)
    }

    // Get current field value
    var currentValue: CFTypeRef?
    let getStatus = AXUIElementCopyAttributeValue(
      focusedElement, kAXValueAttribute as CFString, &currentValue
    )

    var finalValue: String
    if getStatus == .success, let current = currentValue as? String {
      // Remove what we previously inserted, add the new text
      if current.hasSuffix(insertedText) && !insertedText.isEmpty {
        let prefix = String(current.dropLast(insertedText.count))
        finalValue = prefix + newText
      } else {
        // Can't find our inserted text - just append
        finalValue = current.isEmpty ? newText : current
      }
    } else {
      finalValue = newText
    }

    let setResult = AXUIElementSetAttributeValue(
      focusedElement, kAXValueAttribute as CFString, finalValue as CFTypeRef
    )

    if setResult == .success {
      recordAccessibilityWrite()
      insertedText = newText
      confirmedCharCount = insertedText.count
      return .applied
    } else {
      deferToStandardDelivery(
        reason: "replaceInsertedText failed with AXError: \(setResult.rawValue)",
        error: TextOutputError.unableToSetValue(setResult)
      )
      return usingClipboardFallback ? .deferred : .failed(lastError ?? TextOutputError.unableToSetValue(setResult))
    }
  }

  private func insertFresh(_ text: String) -> FinalizationResult {
    guard let focusedElement = getFocusedTextElement() else {
      deferToStandardDelivery(
        reason: "insertFresh failed: no focused element",
        error: TextOutputError.unableToFindFocusedElement
      )
      return usingClipboardFallback ? .deferred : .failed(lastError ?? TextOutputError.unableToFindFocusedElement)
    }

    // Get current value and append
    var currentValue: CFTypeRef?
    let getStatus = AXUIElementCopyAttributeValue(
      focusedElement, kAXValueAttribute as CFString, &currentValue
    )

    var newValue: String
    if getStatus == .success, let current = currentValue as? String {
      newValue = current + text
    } else {
      newValue = text
    }

    let setResult = AXUIElementSetAttributeValue(
      focusedElement, kAXValueAttribute as CFString, newValue as CFTypeRef
    )

    if setResult == .success {
      recordAccessibilityWrite()
      insertedText = text
      confirmedCharCount = text.count
      return .applied
    } else {
      deferToStandardDelivery(
        reason: "insertFresh failed with AXError: \(setResult.rawValue)",
        error: TextOutputError.unableToSetValue(setResult)
      )
      return usingClipboardFallback ? .deferred : .failed(lastError ?? TextOutputError.unableToSetValue(setResult))
    }
  }

  private func getFocusedTextElement() -> AXUIElement? {
    if let focusedElement = target?.focusedElement {
      return focusedElement
    }
    let systemWideElement = AXUIElementCreateSystemWide()
    var rawFocused: CFTypeRef?
    let copyStatus = AXUIElementCopyAttributeValue(
      systemWideElement, kAXFocusedUIElementAttribute as CFString, &rawFocused
    )

    guard copyStatus == .success, let rawFocused else {
      return nil
    }

    return unsafeBitCast(rawFocused, to: AXUIElement.self)
  }

  /// Verify that text was actually inserted by re-reading the value after a short delay.
  /// Runs on MainActor, so it must avoid semaphore + Task patterns that can deadlock.
  private func verifyInsertion(expected: String, element: AXUIElement) -> Bool {
    // Give the target app a brief moment to apply the AX value change before re-reading it.
    // This synchronous wait avoids the MainActor deadlock caused by waiting on a semaphore
    // while also scheduling the verification work back onto MainActor.
    Thread.sleep(forTimeInterval: 0.05)

    var currentValue: CFTypeRef?
    let getStatus = AXUIElementCopyAttributeValue(
      element, kAXValueAttribute as CFString, &currentValue
    )
    guard getStatus == .success, let currentString = currentValue as? String else {
      return false
    }

    return currentString == expected || currentString.hasSuffix(expected)
  }
}
