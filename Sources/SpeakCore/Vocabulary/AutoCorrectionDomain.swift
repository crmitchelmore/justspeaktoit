import Foundation

/// Persistence contract for auto-correction candidates. Abstracted so
/// behavioural tests can inject delayed or failing stores.
public protocol AutoCorrectionStoring: Sendable {
  func load() async throws -> [AutoCorrectionCandidate]
  func save(_ candidates: [AutoCorrectionCandidate]) async throws
  func deleteAll() async throws
}

extension AutoCorrectionStore: AutoCorrectionStoring {}

/// Platform-neutral core of auto-correction learning: manages correction
/// candidates, counts repeated corrections, and promotes them to
/// PersonalLexiconRules once a threshold is reached.
///
/// Platform wrappers (e.g. the macOS Accessibility-based tracker) observe
/// edited text and feed it in via `recordEdit(original:edited:app:)`.
@VocabularyActor
public final class AutoCorrectionDomain {
  public private(set) var candidates: [AutoCorrectionCandidate] = [] {
    didSet { onChange?(candidates) }
  }
  public var onChange: (@VocabularyActor ([AutoCorrectionCandidate]) -> Void)?
  public var onError: (@VocabularyActor (Error) -> Void)?
  public private(set) var loadError: Error?

  private let store: AutoCorrectionStoring
  private let lexiconService: PersonalLexiconDomain
  private let promotionThreshold: () -> Int

  /// Tail of the serial operation chain. The initial load is the first link,
  /// so every mutation awaits it and a slow load can never overwrite state
  /// mutated immediately after initialisation.
  private var operationTail: Task<Void, Never>?

  /// - Parameters:
  ///   - store: Persistence for correction candidates.
  ///   - lexiconService: Destination for promoted correction rules.
  ///   - promotionThreshold: How many times a correction must be seen before
  ///     it is auto-promoted to a rule (read at evaluation time so settings
  ///     changes take effect immediately).
  public init(
    store: AutoCorrectionStoring,
    lexiconService: PersonalLexiconDomain,
    promotionThreshold: @escaping () -> Int
  ) {
    self.store = store
    self.lexiconService = lexiconService
    self.promotionThreshold = promotionThreshold

    operationTail = Task { @VocabularyActor [weak self] in
      await self?.loadCandidates()
    }
  }

  // MARK: - Public API

  /// Await completion of the initial load (and any queued operations).
  public func waitUntilLoaded() async {
    try? await enqueue { }
  }

  /// Record a user edit of previously inserted transcription text.
  /// Word-level changes are extracted and tracked as correction candidates;
  /// repeated corrections are auto-promoted to lexicon rules.
  ///
  /// Throws if the candidate snapshot could not be persisted, or if a
  /// threshold promotion failed (in which case the candidate is retained so
  /// the promotion can be retried later).
  public func recordEdit(original: String, edited: String, app: String?) async throws {
    try await recordEdit(original: original, edited: edited, app: app, threshold: nil, isCurrent: { true })
  }

  public func recordEdit(
    original: String, edited: String, app: String?, threshold: Int?,
    isCurrent: @escaping @Sendable () -> Bool
  ) async throws {
    if let threshold, !AutoCorrectionLearningPolicy.promotionThresholdRange.contains(threshold) {
      throw DesktopConfigurationError.invalidField("Correction promotion threshold")
    }
    guard !original.isEmpty, edited != original else {
      return
    }

    let changes = WordDiffer.findChanges(original: original, edited: edited)

    guard !changes.isEmpty else {
      return
    }

    try await enqueue {
      guard isCurrent() else { throw CancellationError() }
      let previous = self.candidates
      var promotionError: Error?
      for change in changes {
        do {
          try await self.processChange(change, app: app, threshold: threshold ?? self.promotionThreshold())
        } catch {
          // Promotion failed: the candidate stays pending for retry.
          promotionError = error
        }
      }
      do { try await self.persistCandidates() } catch {
        self.candidates = previous
        throw error
      }
      if let promotionError {
        throw promotionError
      }
    }
  }

  /// Manually promote a candidate to a correction rule.
  /// The candidate is removed only once the lexicon rule is durably saved;
  /// on failure it is retained and the error is rethrown.
  public func promoteCandidate(_ candidate: AutoCorrectionCandidate) async throws {
    try await enqueue {
      try await self.createRuleFromCandidate(candidate)
      let previous = self.candidates
      self.candidates.removeAll { $0.id == candidate.id }
      do {
        try await self.persistCandidates()
      } catch {
        // The rule is durable but the candidate list is not; restore the
        // in-memory state to mirror disk and surface the failure.
        self.candidates = previous
        throw error
      }
    }
  }

  /// Dismiss a candidate (user doesn't want this correction).
  /// Rolls the dismissal back and rethrows if it could not be persisted.
  public func dismissCandidate(id: UUID) async throws {
    try await enqueue {
      guard let index = self.candidates.firstIndex(where: { $0.id == id }) else { return }
      let previous = self.candidates
      self.candidates[index].dismissed = true
      do {
        try await self.persistCandidates()
      } catch {
        self.candidates = previous
        self.onError?(error)
        throw error
      }
    }
  }

  /// Remove a candidate entirely.
  /// Rolls the removal back and rethrows if it could not be persisted.
  public func removeCandidate(id: UUID) async throws {
    try await enqueue {
      let previous = self.candidates
      self.candidates.removeAll { $0.id == id }
      do {
        try await self.persistCandidates()
      } catch {
        self.candidates = previous
        throw error
      }
    }
  }

  /// Clear all candidates.
  /// Rolls the clear back and rethrows if the store could not be emptied.
  public func clearAllCandidates() async throws {
    try await enqueue {
      let previous = self.candidates
      self.candidates.removeAll()
      do {
        try await self.store.deleteAll()
      } catch {
        self.candidates = previous
        throw error
      }
    }
  }

  // MARK: - Private Methods

  /// Run `operation` after every previously queued operation (including the
  /// initial load) has finished, serialising load/mutate/save.
  private func enqueue<T: Sendable>(
    _ operation: @escaping @VocabularyActor () async throws -> T
  ) async throws -> T {
    let previous = operationTail
    let task = Task { @VocabularyActor () throws -> T in
      await previous?.value
      if let loadError = self.loadError { throw loadError }
      return try await operation()
    }
    operationTail = Task { @VocabularyActor in
      _ = try? await task.value
    }
    return try await task.value
  }

  private func loadCandidates() async {
    do {
      let loaded = try await store.load()
      var identifiers = Set<UUID>()
      guard loaded.allSatisfy({
        $0.seenCount > 0 && !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !$0.corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && identifiers.insert($0.id).inserted
      }) else { throw CocoaError(.fileReadCorruptFile) }
      candidates = loaded.filter { !$0.dismissed }
      loadError = nil
    } catch {
      loadError = error
      onError?(error)
    }
  }

  private func persistCandidates() async throws {
    do {
      try await store.save(candidates)
    } catch {
      onError?(error)
      throw error
    }
  }

  /// Update in-memory candidates for one word change. Throws only when a
  /// threshold promotion fails to save its lexicon rule; the candidate is
  /// retained (with its incremented count) in that case.
  private func processChange(_ change: WordChange, app: String?, threshold: Int) async throws {
    let matchKey = "\(change.original.lowercased())→\(change.corrected.lowercased())"

    // Check if we already have this candidate
    if let index = candidates.firstIndex(where: { $0.matchKey == matchKey }) {
      // Increment seen count
      candidates[index] = candidates[index].incrementingSeen(app: app)

      // Check if ready to promote
      if candidates[index].seenCount >= threshold {
        // Remove the candidate only after the rule is durably saved.
        try await createRuleFromCandidate(candidates[index])
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
    }
  }

  private func createRuleFromCandidate(_ candidate: AutoCorrectionCandidate) async throws {
    await lexiconService.waitUntilLoaded()
    if let error = lexiconService.loadError { throw error }
    if lexiconService.rules.contains(where: {
      $0.source == .automatic && $0.canonical.caseInsensitiveCompare(candidate.corrected) == .orderedSame
        && $0.aliases.contains(where: { $0.caseInsensitiveCompare(candidate.original) == .orderedSame })
    }) { return }
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
    } catch {
      throw error
    }
  }
}

extension AutoCorrectionDomain {
    public func reloadAfterMigration() async {
        let previous = operationTail
        let reload = Task { @VocabularyActor in
            await previous?.value
            await self.loadCandidates()
        }
        operationTail = reload
        await reload.value
    }
}
