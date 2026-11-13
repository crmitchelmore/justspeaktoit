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
final class LiveTextInserter: ObservableObject {
  enum FinalizationResult {
    case applied
    case deferred
    case failed(Error)
    case redirected(TextOutputTarget)
    case clipboard(TextOutputError)
  }

  /// What happened to streamed text when a recording was cancelled (issue #1561).
  enum RollbackResult: Equatable {
    /// Nothing from this session reached the field.
    case nothingInserted
    /// The streamed text was removed and the field matches its pre-recording text.
    case removed
    /// The text was left in place because removing it could not be proven safe.
    case kept(reason: String)
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

  /// Whether an accessibility write has already succeeded, even if verification later failed.
  private var hasPerformedAccessibilityWrite: Bool = false

  /// Timestamp of the first successful accessibility write in this session
  /// (latency checkpoint: first character visible in the target app).
  private(set) var firstInsertionAt: Date?

  /// UTF-16 range the finalised text occupies in the target field after the
  /// last successful write, or nil when the session cannot vouch for where its
  /// text landed. Voice Edit's "last dictation" fallback edits exactly this
  /// range (issue #673).
  private(set) var lastInsertedRange: VoiceEditTextRange?

  /// Strategy chosen for the current session.
  private(set) var strategy: InsertionStrategy = .fullValue

  /// Writes this session's text with the chosen strategy.
  private var writer: LiveInsertionWriter?

  /// Whether incremental live updates should pause until finalization.
  private var shouldPauseIncrementalUpdates: Bool = false

  /// Supplies the field the ranged streaming path reads and writes. Left `nil`
  /// in production, where the focused accessibility element is used; tests
  /// substitute an in-memory field to exercise the streaming orchestration.
  var streamingFieldProvider: (() -> StreamingTextField?)?

  /// How long to wait for the target app to apply the first streamed write
  /// before reading it back. Shortened by tests, which have no real app to wait for.
  var streamingVerificationDelay: TimeInterval = 0.05

  /// Injectable focus observations keep routing tests independent of the desktop.
  var appSwitchDecisionProvider: ((TextOutputTarget) -> SmartTextOutput.AppSwitchDecision)?
  var redirectedTargetProvider: (() -> TextOutputTarget)?
  private var writeBlockedByAppSwitch = false

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
      logger.error("Cannot start: accessibility permission missing")
      return
    }

    insertedText = ""
    hasPerformedAccessibilityWrite = false
    self.firstInsertionAt = nil
    self.lastInsertedRange = nil
    self.strategy = strategy
    switch strategy {
    case .fullValue: writer = FullValueInserter(host: self)
    case .rangedStreaming: writer = RangedStreamingInserter(host: self)
    }
    shouldPauseIncrementalUpdates = false
    usingClipboardFallback = false
    isActive = true
    lastError = nil
    self.target = target ?? .capture()
    writeBlockedByAppSwitch = false
    let targetApp = self.target?.applicationName ?? "unknown"
    let strategyName = String(describing: strategy)
    logger.info(
      "Started live insertion session (\(strategyName)), target app: \(targetApp), deferring AX readiness checks"
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
    hasPerformedAccessibilityWrite = false
    self.firstInsertionAt = nil
    self.lastInsertedRange = nil
    self.strategy = .fullValue
    writer = nil
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
    guard capturedTargetAllowsWrite() else { return }

    // Calculate what's new since last confirmed insertion
    let trimmedNew = newText.trimmingCharacters(in: .whitespaces)

    guard let writer else { return }
    writer.update(with: trimmedNew)
    adoptWrittenText(from: writer)
  }

  /// Apply final polished text - replaces what was inserted with polished version
  func applyPolishedFinal(_ polishedText: String) -> FinalizationResult {
    guard shouldUseLiveFinalization else { return .deferred }
    writeBlockedByAppSwitch = false
    if let result = appSwitchFinalizationOverride() { return result }
    let result: FinalizationResult
    if let writer {
      result = writer.finalize(with: polishedText)
      adoptWrittenText(from: writer)
    } else {
      result = .deferred
    }
    guard writeBlockedByAppSwitch else { return result }
    // Focus changed during AX reads. A pinned redirect may proceed, but if
    // focus raced back, copy instead of pasting a second copy over partial text.
    return appSwitchFinalizationOverride() ?? .clipboard(.destinationApplicationChanged)
  }

  /// Removes this session's streamed text after the user cancelled the
  /// recording, and ends the session so no later partial can write again.
  /// Removal happens only when the field still holds exactly its pre-recording
  /// text plus what this session streamed; any other edit leaves it untouched.
  func rollBackForCancellation() -> RollbackResult {
    defer { isActive = false }
    guard isActive, let writer else { return .nothingInserted }
    let result = writer.rollBack()
    insertedText = writer.insertedText
    lastInsertedRange = nil
    switch result {
    case .nothingInserted:
      break
    case .removed:
      logger.info("Cancelled recording: streamed text removed from the target")
    case .kept(let reason):
      logger.warning("Cancelled recording: streamed text kept, \(reason, privacy: .public)")
    }
    return result
  }

  /// Mirrors what the writer has put in the field, for delivery and Voice Edit.
  private func adoptWrittenText(from writer: LiveInsertionWriter) {
    if insertedText != writer.insertedText {
      insertedText = writer.insertedText
    }
    if let range = writer.insertedRange {
      lastInsertedRange = range
    }
  }

  private func appSwitchDecision(for target: TextOutputTarget) -> SmartTextOutput.AppSwitchDecision {
    appSwitchDecisionProvider?(target)
      ?? SmartTextOutput.currentAppSwitchDecision(policy: appSettings.appSwitchDelivery, target: target)
  }

  func capturedTargetAllowsWrite() -> Bool {
    guard let target else { return false }
    if case .deliverToOriginal = appSwitchDecision(for: target) { return true }
    writeBlockedByAppSwitch = true
    return false
  }

  private func appSwitchFinalizationOverride() -> FinalizationResult? {
    guard let target else { return nil }
    switch appSwitchDecision(for: target) {
    case .deliverToOriginal: return nil
    case .keepOnClipboard: return .clipboard(.originalApplicationNotInFront(target.applicationName))
    case .deliverToCurrentApp:
      var destination = redirectedTargetProvider?() ?? TextOutputTarget.capture()
      // Returning to the original field can still finalize its owned region.
      if destination.processIdentifier == target.processIdentifier { return nil }
      guard SmartTextOutput.isUsableRedirectDestination(processIdentifier: destination.processIdentifier) else {
        return .clipboard(.destinationApplicationChanged)
      }
      destination.requiresFrontmostAtDelivery = true
      return .redirected(destination)
    }
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
  func recordAccessibilityWrite() {
    hasPerformedAccessibilityWrite = true
    if self.firstInsertionAt == nil {
      self.firstInsertionAt = Date()
    }
  }

  /// - Parameter textAbsentFromField: pass `true` only after reading the target
  ///   field back and confirming none of this session's text is present, which
  ///   makes a one-shot standard delivery safe even after a successful write.
  func deferToStandardDelivery(
    reason: String, error: Error? = nil, textAbsentFromField: Bool = false
  ) {
    if let error {
      lastError = error
    }

    if textAbsentFromField {
      insertedText = ""
      usingClipboardFallback = true
      logger.info("\(reason, privacy: .public), deferring to standard delivery")
      return
    }

    guard canDeferToStandardDelivery else {
      logger.info("\(reason, privacy: .public)")
      return
    }

    usingClipboardFallback = true
    logger.info("\(reason, privacy: .public), deferring to standard delivery")
  }

  /// The captured field for this session, or `nil` when live insertion must
  /// defer to standard delivery. `begin(target:)` always captures a target, so
  /// a missing or cross-process AX element means the capture failed — current
  /// system focus is deliberately never resolved in its place, because that
  /// is how live text streams into an unrelated app (issue #707).
  func focusedTextElement() -> AXUIElement? {
    guard let target, let focusedElement = target.focusedElement,
          target.capturedElementBelongsToCapturedProcess()
    else {
      return nil
    }
    return focusedElement
  }
}

extension LiveTextInserter: LiveInsertionHost {
  /// The field the streaming path reads and writes: the focused accessibility
  /// element in production, or an injected stand-in under test.
  func streamingField() -> StreamingTextField? {
    if let provider = streamingFieldProvider {
      return provider()
    }
    guard let element = focusedTextElement() else { return nil }
    return AccessibilityStreamingTextField(element: element)
  }

  func recordError(_ error: Error) {
    lastError = error
  }

  func pauseIncrementalUpdates(reason: String) {
    shouldPauseIncrementalUpdates = true
    logger.info("Live updates paused: \(reason, privacy: .public)")
  }
}
