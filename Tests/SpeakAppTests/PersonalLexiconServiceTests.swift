import XCTest
@testable import SpeakApp

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

    let context = PersonalLexiconContext(tags: ["personal"], destinationApplication: nil, recentTranscriptWindow: "Met with Acme")
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

  private func makeService() -> (PersonalLexiconService, URL) {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("personal-lexicon-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let store = PersonalLexiconStore(fileManager: .default, baseDirectory: tempRoot)
    let service = PersonalLexiconService(store: store)
    return (service, tempRoot)
  }
}
