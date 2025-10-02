import Foundation

// MARK: - Domain Models

// Personal lexicon rules capture canonical spellings and contextual hints for corrections.
struct PersonalLexiconRule: Identifiable, Codable, Equatable {
  enum Activation: String, Codable, CaseIterable {
    case automatic
    case requireContextMatch
    case manual
  }

  let id: UUID
  var displayName: String
  var canonical: String
  var aliases: [String]
  var activation: Activation
  var contextTags: Set<String>
  var confidence: PersonalLexiconConfidence
  var notes: String?
  var createdAt: Date
  var updatedAt: Date

  init(
    id: UUID = UUID(),
    displayName: String,
    canonical: String,
    aliases: [String],
    activation: Activation,
    contextTags: Set<String>,
    confidence: PersonalLexiconConfidence,
    notes: String?,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.displayName = displayName
    self.canonical = canonical
    self.aliases = aliases
    self.activation = activation
    self.contextTags = contextTags
    self.confidence = confidence
    self.notes = notes
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  func updatingTimestamps() -> PersonalLexiconRule {
    var copy = self
    copy.updatedAt = Date()
    return copy
  }

  func sanitised() -> PersonalLexiconRule {
    let trimmedCanonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    let uniqueAliases = LinkedHashSet(values: aliases)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .filter { $0.caseInsensitiveCompare(trimmedCanonical) != .orderedSame }
    return PersonalLexiconRule(
      id: id,
      displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
      canonical: trimmedCanonical,
      aliases: uniqueAliases,
      activation: activation,
      contextTags: Set(contextTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }),
      confidence: confidence,
      notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines),
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

struct PersonalLexiconContext: Equatable {
  var tags: Set<String>
  var destinationApplication: String?
  var recentTranscriptWindow: String

  static let empty = PersonalLexiconContext(tags: [], destinationApplication: nil, recentTranscriptWindow: "")
}

enum PersonalLexiconConfidence: String, Codable, CaseIterable {
  case high
  case medium
  case low
}

struct PersonalLexiconCorrectionRecord: Codable, Hashable, Identifiable {
  let id: UUID
  let ruleID: UUID
  let alias: String
  let canonical: String
  let occurrences: Int
  let wasApplied: Bool
  let confidence: PersonalLexiconConfidence
  let reason: String?

  init(
    id: UUID = UUID(),
    ruleID: UUID,
    alias: String,
    canonical: String,
    occurrences: Int,
    wasApplied: Bool,
    confidence: PersonalLexiconConfidence,
    reason: String?
  ) {
    self.id = id
    self.ruleID = ruleID
    self.alias = alias
    self.canonical = canonical
    self.occurrences = occurrences
    self.wasApplied = wasApplied
    self.confidence = confidence
    self.reason = reason
  }
}

struct PersonalLexiconApplicationResult {
  let transformedText: String
  let applied: [PersonalLexiconCorrectionRecord]
  let suggestions: [PersonalLexiconCorrectionRecord]
}

struct PersonalLexiconHistorySummary: Codable, Hashable {
  let applied: [PersonalLexiconCorrectionRecord]
  let suggestions: [PersonalLexiconCorrectionRecord]
  let contextTags: [String]
  let destinationApplication: String?

  init(
    applied: [PersonalLexiconCorrectionRecord],
    suggestions: [PersonalLexiconCorrectionRecord],
    contextTags: [String] = [],
    destinationApplication: String? = nil
  ) {
    self.applied = applied
    self.suggestions = suggestions
    self.contextTags = contextTags
    self.destinationApplication = destinationApplication
  }

  func updatingContext(tags: [String], destination: String?) -> PersonalLexiconHistorySummary {
    PersonalLexiconHistorySummary(
      applied: applied,
      suggestions: suggestions,
      contextTags: tags,
      destinationApplication: destination
    )
  }
}

// MARK: - Utilities

private struct LinkedHashSet<Element: Hashable>: Sequence {
  private let ordered: [Element]

  init(values: [Element]) {
    var seen: Set<Element> = []
    var buffer: [Element] = []
    for value in values {
      if seen.insert(value).inserted {
        buffer.append(value)
      }
    }
    ordered = buffer
  }

  func makeIterator() -> IndexingIterator<[Element]> {
    ordered.makeIterator()
  }
}

extension PersonalLexiconRule {
  func shouldAutoApply(in context: PersonalLexiconContext) -> Bool {
    switch activation {
    case .automatic:
      return true
    case .requireContextMatch:
      guard !contextTags.isEmpty else { return false }
      return !context.tags.isDisjoint(with: contextTags)
    case .manual:
      return false
    }
  }
}
