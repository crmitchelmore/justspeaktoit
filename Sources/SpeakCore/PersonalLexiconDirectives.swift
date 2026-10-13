import Foundation

/// The same lexical reference data for Apple and portable post-processing.
public enum PersonalLexiconDirectives {
  public static func build(
    rules: [PersonalLexiconRule], context: PersonalLexiconContext,
    corrections: PersonalLexiconHistorySummary?
  ) -> [String] {
    var aliases: [String: Set<String>] = [:]
    var confidence: [String: PersonalLexiconConfidence] = [:]
    let rank: [PersonalLexiconConfidence: Int] = [.low: 0, .medium: 1, .high: 2]
    func merge(_ alias: String, _ canonical: String, _ value: PersonalLexiconConfidence) {
      aliases[canonical, default: []].insert(alias)
      if (rank[value] ?? 0) >= (rank[confidence[canonical] ?? .low] ?? 0) { confidence[canonical] = value }
    }
    for rule in rules where rule.shouldAutoApply(in: context) {
      for alias in rule.aliases { merge(alias, rule.canonical, rule.confidence) }
    }
    for record in corrections?.applied ?? [] { merge(record.alias, record.canonical, record.confidence) }
    var result = aliases.keys.sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }.map { canonical in
      let names = (aliases[canonical] ?? []).sorted().joined(separator: ", ")
      return "Normalize \(names) to \"\(canonical)\" (confidence: \(confidence[canonical]?.rawValue ?? "medium"))."
    }
    for suggestion in corrections?.suggestions ?? [] {
      result.append(
        "Suggestion: Only change \"\(suggestion.alias)\" to \"\(suggestion.canonical)\" "
          + "when the conversation matches (confidence: \(suggestion.confidence.rawValue), "
          + "reason: \(suggestion.reason ?? "manual rule"))."
      )
    }
    return result
  }

  /// Bias only automatic rules; manual/context-ineligible rules must not become forced spellings.
  public static func keywords(rules: [PersonalLexiconRule], context: PersonalLexiconContext) -> [String] {
    var seen = Set<String>()
    return rules.filter { $0.shouldAutoApply(in: context) }.map(\.canonical).filter {
      !$0.isEmpty && seen.insert($0.lowercased()).inserted
    }
  }
}
