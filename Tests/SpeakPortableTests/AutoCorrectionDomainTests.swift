import Foundation
import XCTest
@testable import SpeakCore

@VocabularyActor
final class AutoCorrectionDomainTests: XCTestCase {
    func testCancelledWhileInitialLoadIsPending_DoesNotMutateOrPersist() async throws {
        let admission = LearningAdmission()
        let store = CandidateTestStore([], loadHook: { admission.cancel() })
        let lexicon = PersonalLexiconDomain(store: LexiconTestStore([]))
        let domain = AutoCorrectionDomain(store: store, lexiconService: lexicon, promotionThreshold: { 2 })
        do {
            try await domain.recordEdit(original: "Susie", edited: "Susy", app: nil,
                                        threshold: 2, isCurrent: { admission.isCurrent })
            XCTFail("Cancellation during queued load was ignored")
        } catch is CancellationError {}
        XCTAssertTrue(domain.candidates.isEmpty)
        let persisted = await store.snapshot()
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertTrue(lexicon.rules.isEmpty)
    }

    func testCapturedThresholdAndCancelledAdmission_PreserveCanonicalPersistence() async throws {
        let store = CandidateTestStore([])
        let lexicon = PersonalLexiconDomain(store: LexiconTestStore([]))
        let domain = AutoCorrectionDomain(store: store, lexiconService: lexicon, promotionThreshold: { 10 })
        do {
            try await domain.recordEdit(original: "Susie", edited: "Susy", app: "Synthetic",
                                        threshold: 2, isCurrent: { false })
            XCTFail("A stale observation was admitted")
        } catch is CancellationError {}
        XCTAssertTrue(domain.candidates.isEmpty)
        try await domain.recordEdit(original: "Susie", edited: "Susy", app: "Synthetic",
                                    threshold: 2, isCurrent: { true })
        let first = try XCTUnwrap(domain.candidates.first)
        await store.fail(true)
        do {
            try await domain.recordEdit(original: "Susie", edited: "Susy", app: "Synthetic",
                                        threshold: 10, isCurrent: { true })
            XCTFail("A failed save reported success")
        } catch {
            XCTAssertEqual(domain.candidates, [first])
        }
        await store.fail(false)
        try await domain.recordEdit(original: "Susie", edited: "Susy", app: "Synthetic",
                                    threshold: 2, isCurrent: { true })
        XCTAssertTrue(domain.candidates.isEmpty)
        XCTAssertEqual(lexicon.rules.count, 1)
        let persisted = await store.snapshot()
        XCTAssertTrue(persisted.isEmpty)
        do {
            try await domain.recordEdit(original: "Other", edited: "Another", app: nil,
                                        threshold: 1, isCurrent: { true })
            XCTFail("An invalid threshold was accepted")
        } catch {}
        XCTAssertEqual(lexicon.rules.count, 1)
    }

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
    private let loadHook: (@Sendable () -> Void)?
    init(_ candidates: [AutoCorrectionCandidate], delayed: Bool = false, loadHook: (@Sendable () -> Void)? = nil) {
        self.candidates = candidates
        self.delayed = delayed
        self.loadHook = loadHook
    }
    func fail(_ value: Bool) { failing = value }
    func replace(_ values: [AutoCorrectionCandidate]) { candidates = values }
    func snapshot() -> [AutoCorrectionCandidate] { candidates }
    func load() async throws -> [AutoCorrectionCandidate] {
        loadHook?()
        if delayed { try await Task.sleep(for: .milliseconds(20)) }
        return candidates
    }

    func save(_ values: [AutoCorrectionCandidate]) throws {
        if failing { throw CocoaError(.fileWriteNoPermission) }
        candidates = values
    }
    func deleteAll() throws { try save([]) }
}

private final class LearningAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    var isCurrent: Bool { self.lock.withLock { self.current } }
    func cancel() { self.lock.withLock { self.current = false } }
}
