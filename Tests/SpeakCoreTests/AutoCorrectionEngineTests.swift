import XCTest
import SpeakCore

@MainActor
final class AutoCorrectionEngineTests: XCTestCase {
  func testRecordEditImmediatelyAfterInitPreservesExistingCandidates() async throws {
    let existing = AutoCorrectionCandidate(original: "wrold", corrected: "world")
    let store = ControllableAutoCorrectionStore(
      initialCandidates: [existing],
      loadDelayNanoseconds: 100_000_000
    )
    let engine = makeEngine(store: store)

    // Mutate immediately, before the delayed load has completed.
    try await engine.recordEdit(original: "teh cat", edited: "the cat", app: nil)

    XCTAssertEqual(
      Set(engine.candidates.map(\.matchKey)),
      ["wrold→world", "teh→the"],
      "Pre-populated candidates must survive an edit recorded before the load finishes"
    )
    let persisted = await store.savedCandidates
    XCTAssertEqual(Set((persisted ?? []).map(\.matchKey)), ["wrold→world", "teh→the"])
  }

  func testPromotionRemovesCandidateOnlyAfterDurableRuleSave() async throws {
    let candidate = AutoCorrectionCandidate(original: "teh", corrected: "the", seenCount: 1)
    let store = ControllableAutoCorrectionStore(initialCandidates: [candidate])
    let lexiconStore = ControllableLexiconStore(initialRules: [])
    let engine = makeEngine(store: store, lexiconStore: lexiconStore, threshold: 2)
    await engine.waitUntilLoaded()

    try await engine.recordEdit(original: "teh cat", edited: "the cat", app: nil)

    XCTAssertTrue(engine.candidates.isEmpty, "Candidate should be removed after promotion")
    let rules = await lexiconStore.savedRules
    XCTAssertEqual(rules?.map(\.canonical), ["the"], "Promoted rule must be durably saved")
    let persisted = await store.savedCandidates
    XCTAssertEqual(persisted, [], "Candidate removal must be persisted")
  }

  func testFailedLexiconSaveKeepsPromotionCandidateForRetry() async throws {
    let candidate = AutoCorrectionCandidate(original: "teh", corrected: "the", seenCount: 1)
    let store = ControllableAutoCorrectionStore(initialCandidates: [candidate])
    let lexiconStore = ControllableLexiconStore(initialRules: [], failSaves: true)
    let engine = makeEngine(store: store, lexiconStore: lexiconStore, threshold: 2)
    await engine.waitUntilLoaded()

    do {
      try await engine.recordEdit(original: "teh cat", edited: "the cat", app: nil)
      XCTFail("recordEdit should surface the failed promotion")
    } catch {
      // Expected
    }

    XCTAssertEqual(engine.candidates.map(\.matchKey), ["teh→the"], "Candidate must be retained for retry")
    XCTAssertEqual(engine.candidates.first?.seenCount, 2, "Increment should still be recorded")
    let rules = await lexiconStore.savedRules
    XCTAssertNil(rules, "No rule may be reported saved when the lexicon save failed")
    let persisted = await store.savedCandidates
    XCTAssertEqual(persisted?.map(\.matchKey), ["teh→the"], "Retained candidate must stay persisted")
  }

  func testManualPromotionFailureRetainsCandidate() async throws {
    let candidate = AutoCorrectionCandidate(original: "teh", corrected: "the", seenCount: 3)
    let store = ControllableAutoCorrectionStore(initialCandidates: [candidate])
    let lexiconStore = ControllableLexiconStore(initialRules: [], failSaves: true)
    let engine = makeEngine(store: store, lexiconStore: lexiconStore)
    await engine.waitUntilLoaded()

    do {
      try await engine.promoteCandidate(candidate)
      XCTFail("promoteCandidate should rethrow the failed lexicon save")
    } catch {
      // Expected
    }

    XCTAssertEqual(
      engine.candidates.map(\.id),
      [candidate.id],
      "Candidate must remain pending after a failed promotion"
    )
  }

  func testFailedDismissRollsBack() async throws {
    let candidate = AutoCorrectionCandidate(original: "teh", corrected: "the")
    let store = ControllableAutoCorrectionStore(initialCandidates: [candidate])
    let engine = makeEngine(store: store)
    await engine.waitUntilLoaded()

    await store.setFailSaves(true)
    do {
      try await engine.dismissCandidate(id: candidate.id)
      XCTFail("dismissCandidate should rethrow the persistence failure")
    } catch {
      // Expected
    }

    XCTAssertEqual(engine.candidates.first?.dismissed, false, "Dismissal must be rolled back on save failure")
  }

  func testFailedClearAllRollsBack() async throws {
    let candidate = AutoCorrectionCandidate(original: "teh", corrected: "the")
    let store = ControllableAutoCorrectionStore(initialCandidates: [candidate], failDeleteAll: true)
    let engine = makeEngine(store: store)
    await engine.waitUntilLoaded()

    do {
      try await engine.clearAllCandidates()
      XCTFail("clearAllCandidates should rethrow the persistence failure")
    } catch {
      // Expected
    }

    XCTAssertEqual(engine.candidates.map(\.id), [candidate.id], "Clear must be rolled back on delete failure")
  }

  // MARK: - Helpers

  private func makeEngine(
    store: ControllableAutoCorrectionStore,
    lexiconStore: ControllableLexiconStore = ControllableLexiconStore(initialRules: []),
    threshold: Int = 3
  ) -> AutoCorrectionEngine {
    AutoCorrectionEngine(
      store: store,
      lexiconService: PersonalLexiconService(store: lexiconStore),
      promotionThreshold: { threshold }
    )
  }
}

// MARK: - Test doubles

/// In-memory auto-correction store whose load can be delayed and whose saves
/// can be made to fail, for durability tests.
actor ControllableAutoCorrectionStore: AutoCorrectionStoring {
  struct SaveFailure: Error {}

  private let initialCandidates: [AutoCorrectionCandidate]
  private let loadDelayNanoseconds: UInt64
  private var failSaves: Bool
  private let failDeleteAll: Bool
  private(set) var savedCandidates: [AutoCorrectionCandidate]?

  init(
    initialCandidates: [AutoCorrectionCandidate],
    loadDelayNanoseconds: UInt64 = 0,
    failSaves: Bool = false,
    failDeleteAll: Bool = false
  ) {
    self.initialCandidates = initialCandidates
    self.loadDelayNanoseconds = loadDelayNanoseconds
    self.failSaves = failSaves
    self.failDeleteAll = failDeleteAll
  }

  func setFailSaves(_ fail: Bool) {
    failSaves = fail
  }

  func load() async throws -> [AutoCorrectionCandidate] {
    if loadDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: loadDelayNanoseconds)
    }
    return savedCandidates ?? initialCandidates
  }

  func save(_ candidates: [AutoCorrectionCandidate]) async throws {
    if failSaves {
      throw SaveFailure()
    }
    savedCandidates = candidates
  }

  func deleteAll() async throws {
    if failDeleteAll {
      throw SaveFailure()
    }
    savedCandidates = []
  }
}
