import Foundation

// MARK: - Domain Models

// Personal lexicon rules capture canonical spellings and contextual hints for corrections.
public struct PersonalLexiconRule: Identifiable, Codable, Equatable {
  public enum Activation: String, Codable, CaseIterable {
    case automatic
    case requireContextMatch
    case manual
  }

  public let id: UUID
  public var displayName: String
  public var canonical: String
  public var aliases: [String]
  public var activation: Activation
  public var contextTags: Set<String>
  public var confidence: PersonalLexiconConfidence
  public var notes: String?
  public var source: PersonalLexiconRuleSource
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    displayName: String,
    canonical: String,
    aliases: [String],
    activation: Activation,
    contextTags: Set<String>,
    confidence: PersonalLexiconConfidence,
    notes: String?,
    source: PersonalLexiconRuleSource = .manual,
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
    self.source = source
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public func updatingTimestamps() -> PersonalLexiconRule {
    var copy = self
    copy.updatedAt = Date()
    return copy
  }

  public func sanitised() -> PersonalLexiconRule {
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
      source: source,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

public struct PersonalLexiconContext: Equatable {
  public var tags: Set<String>
  public var destinationApplication: String?
  public var recentTranscriptWindow: String

  public init(tags: Set<String>, destinationApplication: String?, recentTranscriptWindow: String) {
    self.tags = tags
    self.destinationApplication = destinationApplication
    self.recentTranscriptWindow = recentTranscriptWindow
  }

  public static let empty = PersonalLexiconContext(tags: [], destinationApplication: nil, recentTranscriptWindow: "")
}

public enum PersonalLexiconConfidence: String, Codable, CaseIterable {
  case high
  case medium
  case low
}

public struct PersonalLexiconCorrectionRecord: Codable, Hashable, Identifiable {
  public let id: UUID
  public let ruleID: UUID
  public let alias: String
  public let canonical: String
  public let occurrences: Int
  public let wasApplied: Bool
  public let confidence: PersonalLexiconConfidence
  public let reason: String?

  public init(
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

public struct PersonalLexiconApplicationResult {
  public let transformedText: String
  public let applied: [PersonalLexiconCorrectionRecord]
  public let suggestions: [PersonalLexiconCorrectionRecord]

  public init(
    transformedText: String,
    applied: [PersonalLexiconCorrectionRecord],
    suggestions: [PersonalLexiconCorrectionRecord]
  ) {
    self.transformedText = transformedText
    self.applied = applied
    self.suggestions = suggestions
  }
}

public struct PersonalLexiconHistorySummary: Codable, Hashable {
  public let applied: [PersonalLexiconCorrectionRecord]
  public let suggestions: [PersonalLexiconCorrectionRecord]
  public let contextTags: [String]
  public let destinationApplication: String?

  public init(
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

  public func updatingContext(tags: [String], destination: String?) -> PersonalLexiconHistorySummary {
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
    for value in values where seen.insert(value).inserted {
      buffer.append(value)
    }
    ordered = buffer
  }

  func makeIterator() -> IndexingIterator<[Element]> {
    ordered.makeIterator()
  }
}

extension PersonalLexiconRule {
  public func shouldAutoApply(in context: PersonalLexiconContext) -> Bool {
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
