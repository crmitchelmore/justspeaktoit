import AppKit
import ApplicationServices
import Foundation
import os.log

/// Monitors text fields after transcription insertion to detect user corrections.
/// When the same correction pattern is seen multiple times, it's promoted to a rule.
@MainActor
final class AutoCorrectionTracker: ObservableObject {
  @Published private(set) var candidates: [AutoCorrectionCandidate] = []
  @Published private(set) var isMonitoring: Bool = false

  private let store: AutoCorrectionStore
  private let lexiconService: PersonalLexiconService
  private let appSettings: AppSettings
  private let log = Logger(subsystem: "com.github.speakapp", category: "AutoCorrectionTracker")

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
    self.store = store
    self.lexiconService = lexiconService
    self.appSettings = appSettings

    Task { [weak self] in
      await self?.loadCandidates()
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
    await createRuleFromCandidate(candidate)
    removeCandidate(id: candidate.id)
  }

  /// Dismiss a candidate (user doesn't want this correction).
  func dismissCandidate(id: UUID) {
    guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
    candidates[index].dismissed = true
    Task { await persistCandidates() }
  }

  /// Remove a candidate entirely.
  func removeCandidate(id: UUID) {
    candidates.removeAll { $0.id == id }
    Task { await persistCandidates() }
  }

  /// Clear all candidates.
  func clearAllCandidates() {
    candidates.removeAll()
    Task {
      do {
        try await store.deleteAll()
      } catch {
        log.error("Failed to delete candidates: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  // MARK: - Private Methods

  private func loadCandidates() async {
    do {
      let loaded = try await store.load()
      candidates = loaded.filter { !$0.dismissed }
      log.info("Loaded \(self.candidates.count, privacy: .public) auto-correction candidates")
    } catch {
      log.error("Failed to load candidates: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func persistCandidates() async {
    do {
      try await store.save(candidates)
    } catch {
      log.error("Failed to save candidates: \(error.localizedDescription, privacy: .public)")
    }
  }

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

    // Check if text was modified
    guard currentString != insertedText else {
      log.debug("Text unchanged, no corrections detected")
      return
    }

    // Find word-level changes
    let changes = WordDiffer.findChanges(original: insertedText, edited: currentString)

    guard !changes.isEmpty else {
      log.debug("No word-level corrections detected (might be a rewrite)")
      return
    }

    log.info("Detected \(changes.count, privacy: .public) potential corrections")

    // Process each change
    for change in changes {
      await processChange(change)
    }
  }

  private func processChange(_ change: WordChange) async {
    let matchKey = "\(change.original.lowercased())→\(change.corrected.lowercased())"

    // Check if we already have this candidate
    if let index = candidates.firstIndex(where: { $0.matchKey == matchKey }) {
      // Increment seen count
      candidates[index] = candidates[index].incrementingSeen(app: insertionApp)
      log.info(
        "Seen correction '\(change.original, privacy: .public)' → '\(change.corrected, privacy: .public)' \(self.candidates[index].seenCount, privacy: .public) times"
      )

      // Check if ready to promote
      if candidates[index].seenCount >= appSettings.autoCorrectionsPromotionThreshold {
        log.info("Promoting correction to rule")
        await createRuleFromCandidate(candidates[index])
        candidates.remove(at: index)
      }
    } else {
      // New candidate
      var sourceApps: Set<String> = []
      if let app = insertionApp {
        sourceApps.insert(app)
      }

      let candidate = AutoCorrectionCandidate(
        original: change.original,
        corrected: change.corrected,
        sourceApps: sourceApps
      )
      candidates.append(candidate)
      log.info(
        "New correction candidate: '\(change.original, privacy: .public)' → '\(change.corrected, privacy: .public)'"
      )
    }

    await persistCandidates()
  }

  private func createRuleFromCandidate(_ candidate: AutoCorrectionCandidate) async {
    do {
      _ = try await lexiconService.addRule(
        displayName: candidate.corrected,
        canonical: candidate.corrected,
        aliases: [candidate.original],
        activation: .automatic,
        contextTags: [],
        confidence: .medium,
        notes: "Auto-created from repeated corrections",
        source: .automatic
      )
      log.info(
        "Created auto-correction rule: '\(candidate.original, privacy: .public)' → '\(candidate.corrected, privacy: .public)'"
      )
    } catch {
      log.error("Failed to create rule: \(error.localizedDescription, privacy: .public)")
    }
  }
}
