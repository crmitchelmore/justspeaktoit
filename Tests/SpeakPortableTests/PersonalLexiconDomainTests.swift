import Foundation
import XCTest
@testable import SpeakCore

@VocabularyActor
final class PersonalLexiconDomainTests: XCTestCase {
    func testStoreInitializersPrepareDirectoriesAndReportFailureBeforeRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = PersonalLexiconStore(baseDirectory: root)
        let app = root.appendingPathComponent(ReleaseTrain.current.supportDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("PersonalLexicon").path))
        let automatic = AutoCorrectionStore(fileManager: .default, baseDirectory: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("AutoCorrections").path))
        var saved = rule("Synthetic", alias: "Synthetik")
        saved.createdAt = Date(timeIntervalSince1970: 1_750_000_000)
        saved.updatedAt = saved.createdAt
        try await legacy.save([saved])
        let direct = PersonalLexiconStore(appDirectory: app)
        let loaded = try await direct.load()
        XCTAssertEqual(loaded, [saved])
        let candidates = try await automatic.load()
        XCTAssertTrue(candidates.isEmpty)

        let blocked = root.appendingPathComponent("blocked")
        try Data("synthetic obstruction".utf8).write(to: blocked)
        let inaccessible = PersonalLexiconStore(appDirectory: blocked)
        let inaccessibleCandidates = AutoCorrectionStore(appDirectory: blocked)
        do { _ = try await inaccessible.load(); XCTFail("Initialization failure must reach load") } catch {}
        do {
            try await inaccessibleCandidates.save([])
            XCTFail("Initialization failure must reach even an empty save")
        } catch {}
        try FileManager.default.removeItem(at: blocked)
        try await inaccessible.save([saved])
        let recovered = try await inaccessible.load()
        XCTAssertEqual(recovered, [saved])
        let recoveredCandidates = try await inaccessibleCandidates.load()
        XCTAssertTrue(recoveredCandidates.isEmpty)
    }

    private func rule(_ canonical: String, alias: String, activation: PersonalLexiconRule.Activation = .automatic)
        -> PersonalLexiconRule {
        .init(displayName: canonical, canonical: canonical, aliases: [alias], activation: activation,
              contextTags: ["work"], confidence: .high, notes: nil)
    }

    func testMatchingContextManualAndLiteralReplacement() async throws {
        let rules = [rule("$Susy\\", alias: "Susie"), rule("AcmeCorp", alias: "Acme", activation: .requireContextMatch),
                     rule("Jonathan", alias: "Jon", activation: .manual)]
        let domain = PersonalLexiconDomain(store: LexiconTestStore(rules))
        await domain.waitUntilLoaded()
        let result = domain.apply(to: "Susie, SUSIE! Susies Acme Jon", context: .empty)
        XCTAssertEqual(result.transformedText, "$Susy\\, $Susy\\! Susies Acme Jon")
        XCTAssertEqual(result.applied.map(\.occurrences), [2])
        XCTAssertEqual(
            result.suggestions.map(\.reason), ["Context tags did not match", "Rule requires manual confirmation"]
        )
        let context = PersonalLexiconContext(tags: ["work"], destinationApplication: nil, recentTranscriptWindow: "")
        XCTAssertEqual(domain.apply(to: "Acme Jon", context: context).transformedText, "AcmeCorp Jon")
        XCTAssertEqual(PersonalLexiconDirectives.keywords(rules: rules, context: .empty), ["$Susy\\"])
        let directives = PersonalLexiconDirectives.build(
            rules: rules, context: .empty, corrections: .init(applied: result.applied, suggestions: result.suggestions)
        )
        XCTAssertTrue(directives.contains { $0.contains("Suggestion: Only change \"Jon\"") })
    }

    func testLoadMutationSerializationRollbackAndDurableOrder() async throws {
        let first = rule("Zed", alias: "zeded"), second = rule("Alpha", alias: "alfa")
        let store = LexiconTestStore([first, second], delayed: true)
        let domain = PersonalLexiconDomain(store: store)
        let added = try await domain.addRule(
            displayName: " Middle ", canonical: " Middle ", aliases: [" mid ", "Middle", ""], activation: .automatic,
            contextTags: [" work "], confidence: .medium, notes: " note "
        )
        XCTAssertEqual(domain.rules.map(\.id), [first.id, second.id, added.id])
        XCTAssertEqual(added.aliases, ["mid"])
        XCTAssertEqual(added.notes, "note")
        XCTAssertEqual(added.contextTags, ["work"])
        try await domain.moveRules(from: IndexSet(integer: 2), to: 0)
        let loaded = PersonalLexiconDomain(store: store)
        await loaded.waitUntilLoaded()
        XCTAssertEqual(loaded.rules.map(\.id), [added.id, first.id, second.id])
        let previous = domain.rules
        await store.fail(true)
        do { try await domain.deleteRule(id: first.id); XCTFail("Save must fail") } catch {}
        XCTAssertEqual(domain.rules, previous)
        var updated = added; updated.canonical = "Changed"
        do { try await domain.updateRule(updated); XCTFail("Save must fail") } catch {}
        XCTAssertEqual(domain.rules, previous)
        do { try await domain.moveRules(from: IndexSet(integer: 0), to: 3); XCTFail("Save must fail") } catch {}
        XCTAssertEqual(domain.rules, previous)
    }

    func testCorruptionFailsClosedWithoutOverwritingRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalLexiconStore(baseDirectory: root)
        try await store.save([rule("Good", alias: "goood")])
        let file = root.appendingPathComponent(ReleaseTrain.current.supportDirectory)
            .appendingPathComponent("PersonalLexicon").appendingPathComponent("lexicon.json")
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: file)
        let domain = PersonalLexiconDomain(store: store)
        await domain.waitUntilLoaded()
        XCTAssertNotNil(domain.loadError)
        do {
            _ = try await domain.addRule(displayName: "New", canonical: "New", aliases: ["Nwe"],
                                         activation: .automatic, contextTags: [], confidence: .high, notes: nil)
            XCTFail("Cannot mutate corrupt store")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
}

actor LexiconTestStore: PersonalLexiconStoring {
    var rules: [PersonalLexiconRule]
    var failing = false
    let delayed: Bool
    init(_ rules: [PersonalLexiconRule], delayed: Bool = false) { self.rules = rules; self.delayed = delayed }
    func fail(_ value: Bool) { failing = value }
    func load() async throws -> [PersonalLexiconRule] {
        if delayed { try await Task.sleep(for: .milliseconds(20)) }
        return rules
    }
    func save(_ rules: [PersonalLexiconRule]) throws {
        if failing { throw CocoaError(.fileWriteNoPermission) }
        self.rules = rules
    }
}
