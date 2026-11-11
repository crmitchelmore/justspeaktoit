import Foundation
import Combine
import os.log

/// Apple observation adapter; persistence, ordering and matching live in the portable domain.
@MainActor
public final class PersonalLexiconService: ObservableObject {
  @Published public private(set) var rules: [PersonalLexiconRule] = []
  public let domain: PersonalLexiconDomain

  public init(store: PersonalLexiconStoring) {
    domain = PersonalLexiconDomain(store: store)
    domain.onChange = { [weak self] in self?.rules = $0 }
    let log = SpeakLogger.logger(category: "PersonalLexicon")
    domain.onError = { error in
      log.error("Personal lexicon operation failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  public func waitUntilLoaded() async { await domain.waitUntilLoaded() }
  public func refresh() async { await domain.refresh() }

  // swiftlint:disable:next function_parameter_count
  public func addRule(
    displayName: String, canonical: String, aliases: [String],
    activation: PersonalLexiconRule.Activation, contextTags: Set<String>,
    confidence: PersonalLexiconConfidence, notes: String?,
    source: PersonalLexiconRuleSource = .manual
  ) async throws -> PersonalLexiconRule {
    try await domain.addRule(
      displayName: displayName, canonical: canonical, aliases: aliases, activation: activation,
      contextTags: contextTags, confidence: confidence, notes: notes, source: source
    )
  }

  public func updateRule(_ rule: PersonalLexiconRule) async throws { try await domain.updateRule(rule) }
  public func deleteRule(id: UUID) async throws { try await domain.deleteRule(id: id) }
  public func moveRules(from offsets: IndexSet, to destination: Int) async throws {
    try await domain.moveRules(from: offsets, to: destination)
  }
  public func apply(to text: String, context: PersonalLexiconContext) -> PersonalLexiconApplicationResult {
    domain.apply(to: text, context: context)
  }
  public func activeRules(for context: PersonalLexiconContext) -> [PersonalLexiconRule] {
    domain.activeRules(for: context)
  }
}
