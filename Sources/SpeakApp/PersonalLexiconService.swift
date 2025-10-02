import Foundation
import os.log

@MainActor
final class PersonalLexiconService: ObservableObject {
  @Published private(set) var rules: [PersonalLexiconRule] = []

  private let store: PersonalLexiconStore
  private let log = Logger(subsystem: "com.github.speakapp", category: "PersonalLexicon")

  init(store: PersonalLexiconStore) {
    self.store = store
    Task { [weak self] in
      await self?.loadInitialRules()
    }
  }

  func refresh() async {
    do {
      let loaded = try await store.load()
      rules = Self.normalised(rules: loaded)
    } catch {
      log.error("Failed to refresh lexicon: \(error.localizedDescription, privacy: .public)")
    }
  }

  func addRule(
    displayName: String,
    canonical: String,
    aliases: [String],
    activation: PersonalLexiconRule.Activation,
    contextTags: Set<String>,
    confidence: PersonalLexiconConfidence,
    notes: String?
  ) async throws -> PersonalLexiconRule {
    var rule = PersonalLexiconRule(
      displayName: displayName,
      canonical: canonical,
      aliases: aliases,
      activation: activation,
      contextTags: contextTags,
      confidence: confidence,
      notes: notes
    ).sanitised()

    guard !rule.canonical.isEmpty else {
      throw PersonalLexiconServiceError.invalidCanonical
    }
    guard !rule.aliases.isEmpty else {
      throw PersonalLexiconServiceError.missingAlias
    }

    rule = rule.updatingTimestamps()

    rules.append(rule)
    rules = Self.normalised(rules: rules)
    await persistSnapshot()
    return rule
  }

  func updateRule(_ rule: PersonalLexiconRule) async throws {
    guard let index = rules.firstIndex(where: { $0.id == rule.id }) else {
      throw PersonalLexiconServiceError.unknownRule
    }

    let sanitisedRule = rule.sanitised().updatingTimestamps()
    guard !sanitisedRule.canonical.isEmpty else {
      throw PersonalLexiconServiceError.invalidCanonical
    }
    guard !sanitisedRule.aliases.isEmpty else {
      throw PersonalLexiconServiceError.missingAlias
    }

    rules[index] = sanitisedRule
    rules = Self.normalised(rules: rules)
    await persistSnapshot()
  }

  func deleteRule(id: UUID) async {
    rules.removeAll { $0.id == id }
    await persistSnapshot()
  }

  func moveRules(from offsets: IndexSet, to destination: Int) async {
    var mutable = rules
    mutable.move(fromOffsets: offsets, toOffset: destination)
    rules = mutable
    await persistSnapshot()
  }

  func apply(to text: String, context: PersonalLexiconContext) -> PersonalLexiconApplicationResult {
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
        if matches == 0 {
          continue
        }

        if eligibleForAutoApply {
          workingText = replacedText
          let record = PersonalLexiconCorrectionRecord(
            ruleID: rule.id,
            alias: aliasPattern,
            canonical: rule.canonical,
            occurrences: matches,
            wasApplied: true,
            confidence: rule.confidence,
            reason: reasonBase
          )
          applied.append(record)
        } else {
          let record = PersonalLexiconCorrectionRecord(
            ruleID: rule.id,
            alias: aliasPattern,
            canonical: rule.canonical,
            occurrences: matches,
            wasApplied: false,
            confidence: rule.confidence,
            reason: reasonBase
          )
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

  func activeRules(for context: PersonalLexiconContext) -> [PersonalLexiconRule] {
    rules.filter { $0.shouldAutoApply(in: context) }
  }

  private func loadInitialRules() async {
    do {
      let loaded = try await store.load()
      await MainActor.run {
        self.rules = Self.normalised(rules: loaded)
      }
    } catch {
      log.error("Failed to load lexicon: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func persistSnapshot() async {
    let snapshot = rules
    do {
      try await store.save(snapshot)
    } catch {
      log.error("Failed to persist lexicon: \(error.localizedDescription, privacy: .public)")
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
    let escapedAlias = NSRegularExpression.escapedPattern(for: alias)
    let pattern = "(?i)\\b\(escapedAlias)\\b"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return (0, text)
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

enum PersonalLexiconServiceError: LocalizedError {
  case invalidCanonical
  case missingAlias
  case unknownRule

  var errorDescription: String? {
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
