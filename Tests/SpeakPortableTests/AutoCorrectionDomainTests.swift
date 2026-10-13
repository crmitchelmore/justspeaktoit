import Foundation
import XCTest
@testable import SpeakCore

@MainActor
final class AutoCorrectionDomainTests: XCTestCase {
    func testCandidatePersistenceRollbackAndPromotionRetryDoesNotDuplicateRules() async throws {
        let lexicon = PersonalLexiconDomain(store: LexiconTestStore([]))
        let store = CandidateTestStore([])
        let domain = AutoCorrectionDomain(store: store, lexiconService: lexicon, promotionThreshold: { 3 })
        try await domain.recordEdit(original: "Susie", edited: "Susy", app: "Synthetic")
        let candidate = try XCTUnwrap(domain.candidates.first)
        await store.fail(true)
        do {
            try await domain.recordEdit(original: "Susie", edited: "Susy", app: "Synthetic")
            XCTFail("Candidate save must fail")
        } catch {}
        XCTAssertEqual(domain.candidates, [candidate])
        do {
            try await domain.dismissCandidate(id: candidate.id)
            XCTFail("Dismissal save must fail")
        } catch {}
        XCTAssertEqual(domain.candidates, [candidate])
        do {
            try await domain.promoteCandidate(candidate)
            XCTFail("Candidate removal must fail after the rule is saved")
        } catch {}
        XCTAssertEqual(domain.candidates, [candidate])
        XCTAssertEqual(lexicon.rules.count, 1)
        await store.fail(false)
        try await domain.promoteCandidate(candidate)
        XCTAssertTrue(domain.candidates.isEmpty)
        XCTAssertEqual(lexicon.rules.count, 1, "Retry must not create a second durable automatic rule")
        XCTAssertEqual(lexicon.rules.first?.source, .automatic)
        let context = PersonalLexiconContext.empty
        XCTAssertEqual(lexicon.apply(to: "Susie", context: context).transformedText, "Susy")
    }

    func testDelayedLoadThresholdAndNoInput() async throws {
        let existing = AutoCorrectionCandidate(original: "Susie", corrected: "Susy", seenCount: 2)
        let store = CandidateTestStore([existing], delayed: true)
        let lexicon = PersonalLexiconDomain(store: LexiconTestStore([]))
        let domain = AutoCorrectionDomain(store: store, lexiconService: lexicon, promotionThreshold: { 3 })
        try await domain.recordEdit(original: "Susie", edited: "Susy", app: nil)
        XCTAssertTrue(domain.candidates.isEmpty)
        XCTAssertEqual(lexicon.rules.count, 1)
        try await domain.recordEdit(original: "", edited: "text", app: nil)
        try await domain.recordEdit(original: "unchanged", edited: "unchanged", app: nil)
        XCTAssertTrue(domain.candidates.isEmpty)
    }

    func testInvalidCandidateLoadFailsClosedAndReloadCanRecover() async throws {
        let invalid = AutoCorrectionCandidate(original: "", corrected: "Susy", seenCount: 0)
        let store = CandidateTestStore([invalid])
        let lexicon = PersonalLexiconDomain(store: LexiconTestStore([]))
        let domain = AutoCorrectionDomain(store: store, lexiconService: lexicon, promotionThreshold: { 3 })
        await domain.waitUntilLoaded()
        XCTAssertNotNil(domain.loadError)
        do { try await domain.clearAllCandidates(); XCTFail("Corrupt load must not be overwritten") } catch {}
        let retained = await store.snapshot()
        XCTAssertEqual(retained, [invalid])
        await store.replace([])
        await domain.reloadAfterMigration()
        XCTAssertNil(domain.loadError)
        try await domain.recordEdit(original: "Susie", edited: "Susy", app: nil)
        XCTAssertEqual(domain.candidates.count, 1)
    }
}

private actor CandidateTestStore: AutoCorrectionStoring {
    private var candidates: [AutoCorrectionCandidate]
    private var failing = false
    private let delayed: Bool
    init(_ candidates: [AutoCorrectionCandidate], delayed: Bool = false) {
        self.candidates = candidates
        self.delayed = delayed
    }
    func fail(_ value: Bool) { failing = value }
    func replace(_ values: [AutoCorrectionCandidate]) { candidates = values }
    func snapshot() -> [AutoCorrectionCandidate] { candidates }
    func load() async throws -> [AutoCorrectionCandidate] {
        if delayed { try await Task.sleep(for: .milliseconds(20)) }
        return candidates
    }
    func save(_ values: [AutoCorrectionCandidate]) throws {
        if failing { throw CocoaError(.fileWriteNoPermission) }
        candidates = values
    }
    func deleteAll() throws { try save([]) }
}
