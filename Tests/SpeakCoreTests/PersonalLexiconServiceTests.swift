import XCTest
import SpeakCore

@MainActor
final class PersonalLexiconServiceTests: XCTestCase {
  func testAutomaticRuleAppliesReplacement() async throws {
    let (service, directory) = makeService()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    _ = try await service.addRule(
      displayName: "Susy",
      canonical: "Susy",
      aliases: ["Susie"],
      activation: .automatic,
      contextTags: [],
      confidence: .high,
      notes: nil
    )

    let context = PersonalLexiconContext(tags: [], destinationApplication: nil, recentTranscriptWindow: "Hey Susie!")
    let result = service.apply(to: "Hey Susie!", context: context)

    XCTAssertEqual(result.transformedText, "Hey Susy!")
    XCTAssertEqual(result.applied.count, 1)
    XCTAssertTrue(result.suggestions.isEmpty)
  }

  func testContextRequirementSkipsWhenTagsDoNotMatch() async throws {
    let (service, directory) = makeService()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    _ = try await service.addRule(
      displayName: "Client name",
      canonical: "AcmeCorp",
      aliases: ["Acme"],
      activation: .requireContextMatch,
      contextTags: ["work"],
      confidence: .medium,
      notes: nil
    )

    let context = PersonalLexiconContext(
      tags: ["personal"], destinationApplication: nil, recentTranscriptWindow: "Met with Acme"
    )
    let result = service.apply(to: "Met with Acme", context: context)

    XCTAssertEqual(result.transformedText, "Met with Acme")
    XCTAssertTrue(result.applied.isEmpty)
    XCTAssertEqual(result.suggestions.count, 1)
  }

  func testManualRuleProducesSuggestion() async throws {
    let (service, directory) = makeService()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    _ = try await service.addRule(
      displayName: "Nickname",
      canonical: "Jonathan",
      aliases: ["Jon"],
      activation: .manual,
      contextTags: [],
      confidence: .low,
      notes: "Only change when explicitly requested"
    )

    let context = PersonalLexiconContext(tags: [], destinationApplication: nil, recentTranscriptWindow: "Chat with Jon")
    let result = service.apply(to: "Chat with Jon", context: context)

    XCTAssertEqual(result.transformedText, "Chat with Jon")
    XCTAssertTrue(result.applied.isEmpty)
    XCTAssertEqual(result.suggestions.count, 1)
    XCTAssertEqual(result.suggestions.first?.confidence, .low)
  }

  // MARK: - Durability

  func testMutationImmediatelyAfterInitDoesNotOverwriteSlowLoad() async throws {
    let existing = PersonalLexiconRule(
      displayName: "Existing",
      canonical: "Existing",
      aliases: ["Existng"],
      activation: .automatic,
      contextTags: [],
      confidence: .high,
      notes: nil
    )
    let store = ControllableLexiconStore(initialRules: [existing], loadDelayNanoseconds: 100_000_000)
    let service = PersonalLexiconService(store: store)

    // Mutate immediately, before the delayed load has completed.
    _ = try await service.addRule(
      displayName: "New",
      canonical: "New",
      aliases: ["Nwe"],
      activation: .automatic,
      contextTags: [],
      confidence: .high,
      notes: nil
    )

    XCTAssertEqual(
      Set(service.rules.map(\.canonical)),
      ["Existing", "New"],
      "Pre-populated rules must survive a mutation issued before the load finishes"
    )
    let persisted = await store.savedRules
    XCTAssertEqual(Set((persisted ?? []).map(\.canonical)), ["Existing", "New"])
  }

  func testFailedSaveRollsBackAddedRule() async throws {
    let store = ControllableLexiconStore(initialRules: [], failSaves: true)
    let service = PersonalLexiconService(store: store)
    await service.waitUntilLoaded()

    do {
      _ = try await service.addRule(
        displayName: "Susy",
        canonical: "Susy",
        aliases: ["Susie"],
        activation: .automatic,
        contextTags: [],
        confidence: .high,
        notes: nil
      )
      XCTFail("addRule should rethrow the persistence failure")
    } catch {
      // Expected
    }

    XCTAssertTrue(service.rules.isEmpty, "Optimistic mutation must be rolled back on save failure")
  }

  func testFailedSaveRollsBackDeletion() async throws {
    let rule = PersonalLexiconRule(
      displayName: "Keep",
      canonical: "Keep",
      aliases: ["Kepe"],
      activation: .automatic,
      contextTags: [],
      confidence: .high,
      notes: nil
    )
    let store = ControllableLexiconStore(initialRules: [rule])
    let service = PersonalLexiconService(store: store)
    await service.waitUntilLoaded()
    XCTAssertEqual(service.rules.count, 1)

    await store.setFailSaves(true)
    do {
      try await service.deleteRule(id: rule.id)
      XCTFail("deleteRule should rethrow the persistence failure")
    } catch {
      // Expected
    }

    XCTAssertEqual(service.rules.map(\.id), [rule.id], "Deletion must be rolled back on save failure")
  }

  private func makeService() -> (PersonalLexiconService, URL) {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("personal-lexicon-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let store = PersonalLexiconStore(fileManager: .default, baseDirectory: tempRoot)
    let service = PersonalLexiconService(store: store)
    return (service, tempRoot)
  }
}

// MARK: - Test doubles

/// In-memory lexicon store whose load can be delayed and whose saves can be
/// made to fail, for durability tests.
actor ControllableLexiconStore: PersonalLexiconStoring {
  struct SaveFailure: Error {}

  private let initialRules: [PersonalLexiconRule]
  private let loadDelayNanoseconds: UInt64
  private var failSaves: Bool
  private(set) var savedRules: [PersonalLexiconRule]?

  init(
    initialRules: [PersonalLexiconRule],
    loadDelayNanoseconds: UInt64 = 0,
    failSaves: Bool = false
  ) {
    self.initialRules = initialRules
    self.loadDelayNanoseconds = loadDelayNanoseconds
    self.failSaves = failSaves
  }

  func setFailSaves(_ fail: Bool) {
    failSaves = fail
  }

  func load() async throws -> [PersonalLexiconRule] {
    if loadDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: loadDelayNanoseconds)
    }
    return savedRules ?? initialRules
  }

  func save(_ rules: [PersonalLexiconRule]) async throws {
    if failSaves {
      throw SaveFailure()
    }
    savedRules = rules
  }
}
