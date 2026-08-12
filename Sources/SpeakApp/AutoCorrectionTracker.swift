import AppKit
import ApplicationServices
import Combine
import Foundation
import SpeakCore
import os.log

/// Monitors text fields after transcription insertion to detect user corrections.
/// When the same correction pattern is seen multiple times, it's promoted to a rule.
///
/// Thin macOS wrapper: the Accessibility (AXUIElement) monitoring lives here,
/// while candidate tracking and promotion is delegated to SpeakCore's
/// AutoCorrectionEngine.
@MainActor
final class AutoCorrectionTracker: ObservableObject {
  @Published private(set) var isMonitoring: Bool = false

  var candidates: [AutoCorrectionCandidate] { engine.candidates }

  private let engine: AutoCorrectionEngine
  private let appSettings: AppSettings
  private let log = SpeakLogger.logger(category: "AutoCorrectionTracker")
  private var engineChanges: AnyCancellable?

  private var monitoringTask: Task<Void, Never>?
  private var insertedText: String = ""
  private var insertedElement: AXUIElement?
  private var insertionApp: String?

  /// Base monitoring duration in seconds
  private let baseMonitorDuration: TimeInterval = 10.0
  /// Additional seconds per sentence
  private let perSentenceDuration: TimeInterval = 1.0
  /// Maximum monitoring duration
  private let maxMonitorDuration: TimeInterval = 30.0

  init(store: AutoCorrectionStore, lexiconService: PersonalLexiconService, appSettings: AppSettings) {
    self.engine = AutoCorrectionEngine(
      store: store,
      lexiconService: lexiconService,
      promotionThreshold: { appSettings.autoCorrectionsPromotionThreshold }
    )
    self.appSettings = appSettings

    // Re-publish engine changes so views observing the tracker stay in sync.
    engineChanges = engine.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
  }

  // MARK: - Public API

  /// Start monitoring a text field after inserting transcribed text.
  /// Call this after `applyPolishedFinal` to track user corrections.
  func startMonitoring(insertedText: String, element: AXUIElement?, app: String?) {
    guard appSettings.autoCorrectionsEnabled else {
      log.debug("Auto-corrections disabled, skipping monitoring")
      return
    }

    // Cancel any existing monitoring
    stopMonitoring()

    self.insertedText = insertedText
    insertedElement = element
    insertionApp = app
    isMonitoring = true

    // Calculate monitoring duration based on text length
    let sentenceCount = countSentences(in: insertedText)
    let duration = min(
      baseMonitorDuration + (Double(sentenceCount) * perSentenceDuration),
      maxMonitorDuration
    )

    log.info(
      "Starting auto-correction monitoring for \(duration, privacy: .public)s (\(sentenceCount, privacy: .public) sentences)"
    )

    monitoringTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(duration))

      guard !Task.isCancelled else { return }
      await self?.checkForEdits()
    }
  }

  /// Stop monitoring (e.g., if user switches apps or starts new recording).
  func stopMonitoring() {
    monitoringTask?.cancel()
    monitoringTask = nil
    insertedText = ""
    insertedElement = nil
    insertionApp = nil
    isMonitoring = false
  }

  /// Manually promote a candidate to a correction rule.
  func promoteCandidate(_ candidate: AutoCorrectionCandidate) async {
    await engine.promoteCandidate(candidate)
  }

  /// Dismiss a candidate (user doesn't want this correction).
  func dismissCandidate(id: UUID) {
    engine.dismissCandidate(id: id)
  }

  /// Remove a candidate entirely.
  func removeCandidate(id: UUID) {
    engine.removeCandidate(id: id)
  }

  /// Clear all candidates.
  func clearAllCandidates() {
    engine.clearAllCandidates()
  }

  // MARK: - Private Methods

  private func countSentences(in text: String) -> Int {
    let sentenceEnders = CharacterSet(charactersIn: ".!?")
    return text.unicodeScalars.filter { sentenceEnders.contains($0) }.count
  }

  private func checkForEdits() async {
    defer {
      isMonitoring = false
      insertedElement = nil
    }

    guard let element = insertedElement, !insertedText.isEmpty else {
      log.debug("No element or text to check for edits")
      return
    }

    // Read current value from the text field
    var currentValue: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValue)

    guard status == .success, let currentString = currentValue as? String else {
      log.debug("Could not read current value from text field")
      return
    }

    await engine.recordEdit(original: insertedText, edited: currentString, app: insertionApp)
  }
}
