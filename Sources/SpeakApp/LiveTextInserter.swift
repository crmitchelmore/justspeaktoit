// swiftlint:disable file_length
import AppKit
import ApplicationServices
import Foundation
import SpeakCore

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

  /// How live text reaches the target app during a session.
  enum InsertionStrategy {
    /// Rewrite the whole field value on every update (existing behaviour).
    case fullValue
    /// Experimental (issue #611): keep the stable prefix untouched and patch
    /// only the unstable tail via ranged `kAXSelectedTextRange` replacement.
    /// Only used for allowlisted apps; any failure drops cleanly back to the
    /// standard one-shot delivery without ever duplicating text.
    case rangedStreaming
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

  /// Strategy chosen for the current session.
  private(set) var strategy: InsertionStrategy = .fullValue

  /// UTF-16 offset in the target field where the streamed region begins
  /// (ranged streaming only). Captured from the caret on first insert.
  private var streamingAnchorUTF16: Int?

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
  func begin(target: TextOutputTarget? = nil, strategy: InsertionStrategy = .fullValue) {
    guard canUseAccessibility() else {
      lastError = TextOutputError.accessibilityPermissionMissing
      print("[LiveTextInserter] Cannot start: accessibility permission missing")
      return
    }

    insertedText = ""
    confirmedCharCount = 0
    firstInsertionVerified = false
    hasPerformedAccessibilityWrite = false
    self.firstInsertionAt = nil
    self.strategy = strategy
    self.streamingAnchorUTF16 = nil
    shouldPauseIncrementalUpdates = false
    usingClipboardFallback = false
    isActive = true
    lastError = nil
    self.target = target ?? .capture()
    let targetApp = self.target?.applicationName ?? "unknown"
    print(
      "[LiveTextInserter] Started live insertion session (\(strategy)), target app: \(targetApp), " +
        "deferring AX readiness checks"
    )
  }

  /// End the live insertion session
  func end() {
    if isActive {
      print("[LiveTextInserter] Ended session, inserted \(insertedText.count) characters")
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
    self.strategy = .fullValue
    self.streamingAnchorUTF16 = nil
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

    if self.strategy == .rangedStreaming {
      streamingUpdate(with: trimmedNew)
      return
    }

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

    if self.strategy == .rangedStreaming {
      return streamingFinalize(with: polishedText)
    }

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
      print("[LiveTextInserter] \(reason)")
      return
    }

    usingClipboardFallback = true
    print("[LiveTextInserter] \(reason), deferring to standard delivery")
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
          print("[LiveTextInserter] First insertion verified successfully")
        } else {
          insertedText = newValue
          confirmedCharCount = insertedText.count
          shouldPauseIncrementalUpdates = true
          lastError = TextOutputError.unableToVerifyInsertion
          print("[LiveTextInserter] First insertion verification failed, pausing incremental updates")
          return
        }
      }

      insertedText += text
      confirmedCharCount = insertedText.count
      print("[LiveTextInserter] Appended \(text.count) chars, total: \(insertedText.count)")
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

// MARK: - Ranged streaming insertion (experimental, issue #611)

extension LiveTextInserter {
  /// Patches the target field so it contains `newText` at the streamed region:
  /// the stable prefix is left untouched and only the differing tail is
  /// replaced through `kAXSelectedTextRange` + `kAXSelectedText`.
  fileprivate func streamingUpdate(with newText: String) {
    guard let element = getFocusedTextElement() else {
      abandonStreaming(
        reason: "no focused element",
        error: TextOutputError.unableToFindFocusedElement
      )
      return
    }

    if self.streamingAnchorUTF16 == nil {
      // First insert: anchor the streamed region at the current caret.
      guard let selection = selectedTextRange(of: element) else {
        abandonStreaming(reason: "cannot read caret position", error: nil)
        return
      }
      self.streamingAnchorUTF16 = selection.location
    }

    let diff = StreamingTextReconciler.diff(from: insertedText, to: newText)
    guard !diff.isNoOp else { return }
    guard applyStreamingDiff(diff, on: element) else { return }
    insertedText = newText
    confirmedCharCount = newText.count

    if !firstInsertionVerified {
      verifyFirstStreamingInsertion(on: element)
    }
  }

  /// One clean final pass: transform the streamed region into the final
  /// polished text. Never re-pastes on failure — if text already reached the
  /// app the streamed transcript is left in place rather than duplicated.
  fileprivate func streamingFinalize(with finalText: String) -> FinalizationResult {
    // Nothing ever streamed: hand the whole delivery to the standard path.
    guard !insertedText.isEmpty || hasPerformedAccessibilityWrite else {
      usingClipboardFallback = true
      return .deferred
    }

    guard let element = getFocusedTextElement() else {
      print("[LiveTextInserter] Streaming finalize: focused element lost, keeping streamed text")
      lastError = TextOutputError.unableToFindFocusedElement
      return .applied
    }

    let diff = StreamingTextReconciler.diff(from: insertedText, to: finalText)
    if diff.isNoOp {
      return .applied
    }
    if applyStreamingDiff(diff, on: element) {
      insertedText = finalText
      confirmedCharCount = finalText.count
      return .applied
    }
    if usingClipboardFallback {
      // No text ever reached the app, so the one-shot standard delivery is safe.
      return .deferred
    }
    // A write already landed but the final patch failed: keep the streamed
    // transcript as-is instead of risking a duplicate insert.
    print("[LiveTextInserter] Streaming finalize failed after writes; keeping streamed text")
    return .applied
  }

  /// Selects `diff`'s range (offset by the region anchor) and replaces it.
  /// Returns false after routing any failure through `abandonStreaming`.
  private func applyStreamingDiff(_ diff: StreamingTextDiff, on element: AXUIElement) -> Bool {
    guard let anchor = self.streamingAnchorUTF16 else {
      abandonStreaming(reason: "streaming anchor missing", error: nil)
      return false
    }

    var range = CFRange(
      location: anchor + diff.replaceLocationUTF16,
      length: diff.replaceLengthUTF16
    )
    guard let rangeValue = AXValueCreate(.cfRange, &range) else {
      abandonStreaming(reason: "could not build AX range value", error: nil)
      return false
    }
    let rangeStatus = AXUIElementSetAttributeValue(
      element, kAXSelectedTextRangeAttribute as CFString, rangeValue
    )
    guard rangeStatus == .success else {
      abandonStreaming(
        reason: "selecting replacement range failed (AXError \(rangeStatus.rawValue))",
        error: TextOutputError.unableToSetValue(rangeStatus)
      )
      return false
    }

    let insertStatus = AXUIElementSetAttributeValue(
      element, kAXSelectedTextAttribute as CFString, diff.replacement as CFTypeRef
    )
    guard insertStatus == .success else {
      abandonStreaming(
        reason: "replacing selected text failed (AXError \(insertStatus.rawValue))",
        error: TextOutputError.unableToSetValue(insertStatus)
      )
      return false
    }

    // The diff always extends to the end of the streamed region, so the caret
    // lands at the region end naturally after the replacement.
    recordAccessibilityWrite()
    return true
  }

  /// Reads back the streamed region once after the first write. On mismatch the
  /// session pauses incremental updates and relies on the single finalize pass,
  /// so a misbehaving AX implementation can never garble or duplicate text.
  private func verifyFirstStreamingInsertion(on element: AXUIElement) {
    guard let anchor = self.streamingAnchorUTF16 else { return }
    // Give the target app a brief moment to apply the change (same rationale
    // as verifyInsertion above).
    Thread.sleep(forTimeInterval: 0.05)

    var currentValue: CFTypeRef?
    let getStatus = AXUIElementCopyAttributeValue(
      element, kAXValueAttribute as CFString, &currentValue
    )
    guard getStatus == .success, let fieldText = currentValue as? String,
          let regionText = Self.utf16Substring(
            of: fieldText, location: anchor, length: insertedText.utf16.count
          ),
          regionText == insertedText
    else {
      shouldPauseIncrementalUpdates = true
      lastError = TextOutputError.unableToVerifyInsertion
      print("[LiveTextInserter] Streaming verification failed, pausing until finalize")
      return
    }
    firstInsertionVerified = true
    print("[LiveTextInserter] First streaming insertion verified")
  }

  /// Streaming failure policy: if nothing has reached the app yet, fall back to
  /// the standard one-shot delivery; if text is already on screen, only pause
  /// incremental updates (finalize will do a single clean patch, never a paste).
  private func abandonStreaming(reason: String, error: Error?) {
    if let error {
      lastError = error
    }
    if hasPerformedAccessibilityWrite {
      shouldPauseIncrementalUpdates = true
      print("[LiveTextInserter] Streaming paused: \(reason)")
    } else {
      deferToStandardDelivery(reason: "streaming aborted: \(reason)", error: error)
    }
  }

  private func selectedTextRange(of element: AXUIElement) -> CFRange? {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
      element, kAXSelectedTextRangeAttribute as CFString, &value
    )
    guard status == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
      return nil
    }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    var range = CFRange()
    guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
    return range
  }

  /// UTF-16 based substring with bounds checks; `nil` when the range is out of
  /// bounds or splits a surrogate pair.
  private static func utf16Substring(of text: String, location: Int, length: Int) -> String? {
    let utf16 = text.utf16
    guard location >= 0, length >= 0, location + length <= utf16.count else { return nil }
    let start = utf16.index(utf16.startIndex, offsetBy: location)
    let end = utf16.index(start, offsetBy: length)
    guard let startIndex = start.samePosition(in: text),
          let endIndex = end.samePosition(in: text)
    else { return nil }
    return String(text[startIndex..<endIndex])
  }
}
