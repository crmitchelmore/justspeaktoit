import Foundation
import os.log

/// Platform-neutral core of auto-correction learning: manages correction
/// candidates, counts repeated corrections, and promotes them to
/// PersonalLexiconRules once a threshold is reached.
///
/// Platform wrappers (e.g. the macOS Accessibility-based tracker) observe
/// edited text and feed it in via `recordEdit(original:edited:app:)`.
@MainActor
public final class AutoCorrectionEngine: ObservableObject {
  @Published public private(set) var candidates: [AutoCorrectionCandidate] = []

  private let store: AutoCorrectionStore
  private let lexiconService: PersonalLexiconService
  private let promotionThreshold: () -> Int
  private let log = Logger(subsystem: "com.github.speakapp", category: "AutoCorrectionEngine")

  /// - Parameters:
  ///   - store: Persistence for correction candidates.
  ///   - lexiconService: Destination for promoted correction rules.
  ///   - promotionThreshold: How many times a correction must be seen before
  ///     it is auto-promoted to a rule (read at evaluation time so settings
  ///     changes take effect immediately).
  public init(
    store: AutoCorrectionStore,
    lexiconService: PersonalLexiconService,
    promotionThreshold: @escaping () -> Int
  ) {
    self.store = store
    self.lexiconService = lexiconService
    self.promotionThreshold = promotionThreshold

    Task { [weak self] in
      await self?.loadCandidates()
    }
  }

  // MARK: - Public API

  /// Record a user edit of previously inserted transcription text.
  /// Word-level changes are extracted and tracked as correction candidates;
  /// repeated corrections are auto-promoted to lexicon rules.
  public func recordEdit(original: String, edited: String, app: String?) async {
    guard !original.isEmpty, edited != original else {
      log.debug("Text unchanged, no corrections detected")
      return
    }

    let changes = WordDiffer.findChanges(original: original, edited: edited)

    guard !changes.isEmpty else {
      log.debug("No word-level corrections detected (might be a rewrite)")
      return
    }

    log.info("Detected \(changes.count, privacy: .public) potential corrections")

    for change in changes {
      await processChange(change, app: app)
    }
  }

  /// Manually promote a candidate to a correction rule.
  public func promoteCandidate(_ candidate: AutoCorrectionCandidate) async {
    await createRuleFromCandidate(candidate)
    removeCandidate(id: candidate.id)
  }

  /// Dismiss a candidate (user doesn't want this correction).
  public func dismissCandidate(id: UUID) {
    guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
    candidates[index].dismissed = true
    Task { await persistCandidates() }
  }

  /// Remove a candidate entirely.
  public func removeCandidate(id: UUID) {
    candidates.removeAll { $0.id == id }
    Task { await persistCandidates() }
  }

  /// Clear all candidates.
  public func clearAllCandidates() {
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

  private func processChange(_ change: WordChange, app: String?) async {
    let matchKey = "\(change.original.lowercased())→\(change.corrected.lowercased())"

    // Check if we already have this candidate
    if let index = candidates.firstIndex(where: { $0.matchKey == matchKey }) {
      // Increment seen count
      candidates[index] = candidates[index].incrementingSeen(app: app)
      let seenCount = candidates[index].seenCount
      log.info("Seen correction '\(matchKey, privacy: .public)' \(seenCount, privacy: .public) times")

      // Check if ready to promote
      if candidates[index].seenCount >= promotionThreshold() {
        log.info("Promoting correction to rule")
        await createRuleFromCandidate(candidates[index])
        candidates.remove(at: index)
      }
    } else {
      // New candidate
      var sourceApps: Set<String> = []
      if let app {
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
      let original = candidate.original
      let corrected = candidate.corrected
      log.info(
        "Created auto-correction rule: '\(original, privacy: .public)' → '\(corrected, privacy: .public)'"
      )
    } catch {
      log.error("Failed to create rule: \(error.localizedDescription, privacy: .public)")
    }
  }
}
