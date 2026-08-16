import Foundation
import os.log

/// Persistence contract for the personal lexicon. Abstracted so behavioural
/// tests can inject delayed or failing stores.
public protocol PersonalLexiconStoring: Sendable {
  func load() async throws -> [PersonalLexiconRule]
  func save(_ rules: [PersonalLexiconRule]) async throws
}

extension PersonalLexiconStore: PersonalLexiconStoring {}

@MainActor
public final class PersonalLexiconService: ObservableObject {
  @Published public private(set) var rules: [PersonalLexiconRule] = [] {
    didSet { regexCache.removeAll() }
  }

  private let store: PersonalLexiconStoring
  private let log = SpeakLogger.logger(category: "PersonalLexicon")
  private var regexCache: [String: NSRegularExpression] = [:]

  /// Tail of the serial operation chain. The initial load is the first link,
  /// so every mutation awaits it and load/mutate/save never interleave.
  private var operationTail: Task<Void, Never>?

  public init(store: PersonalLexiconStoring) {
    self.store = store
    operationTail = Task { @MainActor [weak self] in
      await self?.loadInitialRules()
    }
  }

  /// Await completion of the initial load (and any queued operations).
  public func waitUntilLoaded() async {
    try? await enqueue { }
  }

  public func refresh() async {
    do {
      try await enqueue {
        let loaded = try await self.store.load()
        self.rules = Self.normalised(rules: loaded)
      }
    } catch {
      log.error("Failed to refresh lexicon: \(error.localizedDescription, privacy: .public)")
    }
  }

  // swiftlint:disable:next function_parameter_count
  public func addRule(
    displayName: String,
    canonical: String,
    aliases: [String],
    activation: PersonalLexiconRule.Activation,
    contextTags: Set<String>,
    confidence: PersonalLexiconConfidence,
    notes: String?,
    source: PersonalLexiconRuleSource = .manual
  ) async throws -> PersonalLexiconRule {
    var rule = PersonalLexiconRule(
      displayName: displayName,
      canonical: canonical,
      aliases: aliases,
      activation: activation,
      contextTags: contextTags,
      confidence: confidence,
      notes: notes,
      source: source
    ).sanitised()

    guard !rule.canonical.isEmpty else {
      throw PersonalLexiconServiceError.invalidCanonical
    }
    guard !rule.aliases.isEmpty else {
      throw PersonalLexiconServiceError.missingAlias
    }

    rule = rule.updatingTimestamps()
    let newRule = rule

    try await enqueue {
      try await self.mutateAndPersist { current in
        current.append(newRule)
      }
    }
    return rule
  }

  public func updateRule(_ rule: PersonalLexiconRule) async throws {
    let sanitisedRule = rule.sanitised().updatingTimestamps()
    guard !sanitisedRule.canonical.isEmpty else {
      throw PersonalLexiconServiceError.invalidCanonical
    }
    guard !sanitisedRule.aliases.isEmpty else {
      throw PersonalLexiconServiceError.missingAlias
    }

    try await enqueue {
      guard let index = self.rules.firstIndex(where: { $0.id == rule.id }) else {
        throw PersonalLexiconServiceError.unknownRule
      }
      try await self.mutateAndPersist { current in
        current[index] = sanitisedRule
      }
    }
  }

  public func deleteRule(id: UUID) async throws {
    try await enqueue {
      try await self.mutateAndPersist { current in
        current.removeAll { $0.id == id }
      }
    }
  }

  public func moveRules(from offsets: IndexSet, to destination: Int) async throws {
    try await enqueue {
      try await self.mutateAndPersist(normalise: false) { current in
        current.move(fromOffsets: offsets, toOffset: destination)
      }
    }
  }

  public func apply(to text: String, context: PersonalLexiconContext) -> PersonalLexiconApplicationResult {
    guard !rules.isEmpty else {
      return PersonalLexiconApplicationResult(
        transformedText: text,
        applied: [],
        suggestions: []
      )
    }

    let snapshot = rules
    var workingText = text
    var applied: [PersonalLexiconCorrectionRecord] = []
    var suggestions: [PersonalLexiconCorrectionRecord] = []

    for rule in snapshot {
      let eligibleForAutoApply = rule.shouldAutoApply(in: context)
      let reasonBase: String?
      switch rule.activation {
      case .automatic:
        reasonBase = nil
      case .requireContextMatch:
        reasonBase = eligibleForAutoApply ? nil : "Context tags did not match"
      case .manual:
        reasonBase = "Rule requires manual confirmation"
      }

      for alias in rule.aliases {
        let aliasPattern = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !aliasPattern.isEmpty else { continue }

        let (matches, replacedText) = apply(alias: aliasPattern, with: rule.canonical, to: workingText)
        guard matches > 0 else { continue }

        let record = PersonalLexiconCorrectionRecord(
          ruleID: rule.id,
          alias: aliasPattern,
          canonical: rule.canonical,
          occurrences: matches,
          wasApplied: eligibleForAutoApply,
          confidence: rule.confidence,
          reason: reasonBase
        )
        if eligibleForAutoApply {
          workingText = replacedText
          applied.append(record)
        } else {
          suggestions.append(record)
        }
      }
    }

    return PersonalLexiconApplicationResult(
      transformedText: workingText,
      applied: applied,
      suggestions: suggestions
    )
  }

  public func activeRules(for context: PersonalLexiconContext) -> [PersonalLexiconRule] {
    rules.filter { $0.shouldAutoApply(in: context) }
  }

  // MARK: - Serialised persistence

  /// Run `operation` after every previously queued operation (including the
  /// initial load) has finished. Operations therefore never observe a
  /// half-loaded store and an older load can never replace newer changes.
  private func enqueue<T: Sendable>(
    _ operation: @escaping @MainActor () async throws -> T
  ) async throws -> T {
    let previous = operationTail
    let task = Task { @MainActor () throws -> T in
      await previous?.value
      return try await operation()
    }
    operationTail = Task { @MainActor in
      _ = try? await task.value
    }
    return try await task.value
  }

  /// Apply `mutation` optimistically, persist the result, and roll the
  /// in-memory state back if the save fails so memory always mirrors disk.
  private func mutateAndPersist(
    normalise: Bool = true,
    _ mutation: (inout [PersonalLexiconRule]) -> Void
  ) async throws {
    let previous = rules
    var mutated = previous
    mutation(&mutated)
    rules = normalise ? Self.normalised(rules: mutated) : mutated
    do {
      try await store.save(rules)
    } catch {
      rules = previous
      log.error("Failed to persist lexicon: \(error.localizedDescription, privacy: .public)")
      throw error
    }
  }

  private func loadInitialRules() async {
    do {
      let loaded = try await store.load()
      rules = Self.normalised(rules: loaded)
    } catch {
      log.error("Failed to load lexicon: \(error.localizedDescription, privacy: .public)")
    }
  }

  private static func normalised(rules: [PersonalLexiconRule]) -> [PersonalLexiconRule] {
    rules
      .map { $0.sanitised() }
      .filter { !$0.canonical.isEmpty && !$0.aliases.isEmpty }
      .sorted { lhs, rhs in
        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
      }
  }

  private func apply(alias: String, with canonical: String, to text: String) -> (Int, String) {
    let regex: NSRegularExpression
    if let cached = regexCache[alias] {
      regex = cached
    } else {
      let escapedAlias = NSRegularExpression.escapedPattern(for: alias)
      let pattern = "(?i)\\b\(escapedAlias)\\b"
      guard let compiled = try? NSRegularExpression(pattern: pattern, options: []) else {
        return (0, text)
      }
      regexCache[alias] = compiled
      regex = compiled
    }
    let fullRange = NSRange(location: 0, length: text.utf16.count)
    let matches = regex.numberOfMatches(in: text, options: [], range: fullRange)
    guard matches > 0 else { return (0, text) }

    let template = NSRegularExpression.escapedTemplate(for: canonical)
    let replaced = regex.stringByReplacingMatches(
      in: text,
      options: [],
      range: fullRange,
      withTemplate: template
    )
    return (matches, replaced)
  }
}

public enum PersonalLexiconServiceError: LocalizedError {
  case invalidCanonical
  case missingAlias
  case unknownRule

  public var errorDescription: String? {
    switch self {
    case .invalidCanonical:
      return "Canonical term cannot be empty."
    case .missingAlias:
      return "Provide at least one spoken variant."
    case .unknownRule:
      return "Rule does not exist."
    }
  }
}
