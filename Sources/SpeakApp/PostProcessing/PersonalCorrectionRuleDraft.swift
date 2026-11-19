import Foundation
import SpeakCore

/// The editable form state behind the Corrections editor. It owns parsing of
/// the comma-separated fields and the rule it would save, so the views only bind to it.
struct PersonalCorrectionRuleDraft {
  var id: UUID?
  var canonical: String = ""
  var aliasesText: String = ""
  var activation: PersonalLexiconRule.Activation = .automatic
  var contextTagsText: String = ""
  var confidence: PersonalLexiconConfidence = .high
  var notes: String = ""

  var isEditing: Bool { id != nil }

  var canonicalDisplay: String {
    let trimmed = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "New correction" : trimmed
  }

  var aliases: [String] {
    Self.tokenize(aliasesText)
  }

  var tags: Set<String> {
    Set(Self.tokenize(contextTagsText))
  }

  var generatedDisplayName: String {
    if let firstAlias = aliases.first?.trimmingCharacters(in: .whitespacesAndNewlines), !firstAlias.isEmpty {
      return "\(canonicalDisplay) (\(firstAlias))"
    }
    return canonicalDisplay
  }

  var isSavable: Bool {
    !canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !aliases.isEmpty
  }

  var previewTags: Set<String> {
    tags
  }

  /// Notes trimmed of surrounding whitespace, or nil when nothing remains.
  var trimmedNotes: String? {
    let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var requiresAdvancedOptions: Bool {
    if activation != .automatic { return true }
    if confidence != .high { return true }
    if !tags.isEmpty { return true }
    return trimmedNotes != nil
  }

  init() {}

  init(rule: PersonalLexiconRule) {
    id = rule.id
    canonical = rule.canonical
    aliasesText = rule.aliases.joined(separator: ", ")
    activation = rule.activation
    contextTagsText = rule.contextTags.sorted().joined(separator: ", ")
    confidence = rule.confidence
    notes = rule.notes ?? ""
  }

  /// The saved form of this draft applied to `existing`, keeping its identity and creation date.
  func updatedRule(from existing: PersonalLexiconRule, updatedAt: Date) -> PersonalLexiconRule {
    PersonalLexiconRule(
      id: existing.id,
      displayName: generatedDisplayName,
      canonical: canonical,
      aliases: aliases,
      activation: activation,
      contextTags: tags,
      confidence: confidence,
      notes: trimmedNotes,
      createdAt: existing.createdAt,
      updatedAt: updatedAt
    )
  }

  private static func tokenize(_ text: String) -> [String] {
    text
      .split(whereSeparator: { ",\n".contains($0) })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}

/// Display names shared by the editor pickers, saved rule rows and preview rows.
enum PersonalCorrectionLabels {
  static func label(for activation: PersonalLexiconRule.Activation) -> String {
    switch activation {
    case .automatic:
      return "Automatic"
    case .requireContextMatch:
      return "Context match"
    case .manual:
      return "Manual"
    }
  }

  static func label(for confidence: PersonalLexiconConfidence) -> String {
    switch confidence {
    case .high:
      return "High"
    case .medium:
      return "Medium"
    case .low:
      return "Low"
    }
  }
}
