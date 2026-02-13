import XCTest

@testable import SpeakApp

final class AutoCorrectionModelTests: XCTestCase {

    // MARK: - WordChange.isLikelyCorrection

    func testIsLikelyCorrection_similarWords_true() {
        let change = WordChange(type: .replacement, original: "teh", corrected: "the")
        XCTAssertTrue(change.isLikelyCorrection, "Typo fix should be a likely correction")
    }

    func testIsLikelyCorrection_caseChange_true() {
        let change = WordChange(type: .replacement, original: "hello", corrected: "Hello")
        XCTAssertTrue(change.isLikelyCorrection, "Case change should be a likely correction")
    }

    func testIsLikelyCorrection_completelyDifferent_false() {
        let change = WordChange(type: .replacement, original: "cat", corrected: "refrigerator")
        XCTAssertFalse(change.isLikelyCorrection, "Unrelated words should not be a correction")
    }

    func testIsLikelyCorrection_singleCharWords_false() {
        let change = WordChange(type: .replacement, original: "a", corrected: "b")
        XCTAssertFalse(
            change.isLikelyCorrection,
            "Single-char words should not be treated as corrections"
        )
    }

    // MARK: - AutoCorrectionCandidate.matchKey

    func testMatchKey_caseInsensitive() {
        let candidate = AutoCorrectionCandidate(
            original: "Hello",
            corrected: "HELLO",
            seenCount: 1,
            firstSeenAt: Date(),
            lastSeenAt: Date(),
            sourceApps: []
        )
        let candidate2 = AutoCorrectionCandidate(
            original: "hello",
            corrected: "hello",
            seenCount: 1,
            firstSeenAt: Date(),
            lastSeenAt: Date(),
            sourceApps: []
        )
        XCTAssertEqual(
            candidate.matchKey,
            candidate2.matchKey,
            "matchKey should be case-insensitive"
        )
    }

    // MARK: - incrementingSeen

    func testIncrementingSeen_incrementsCount() {
        let candidate = AutoCorrectionCandidate(
            original: "teh",
            corrected: "the",
            seenCount: 1,
            firstSeenAt: Date(),
            lastSeenAt: Date(),
            sourceApps: ["Safari"]
        )
        let updated = candidate.incrementingSeen(app: "Notes")
        XCTAssertEqual(updated.seenCount, 2)
        XCTAssertTrue(updated.sourceApps.contains("Notes"))
        XCTAssertTrue(updated.sourceApps.contains("Safari"))
    }

    func testIncrementingSeen_deduplicatesApps() {
        let candidate = AutoCorrectionCandidate(
            original: "teh",
            corrected: "the",
            seenCount: 1,
            firstSeenAt: Date(),
            lastSeenAt: Date(),
            sourceApps: ["Safari"]
        )
        let updated = candidate.incrementingSeen(app: "Safari")
        XCTAssertEqual(updated.seenCount, 2)
        // App should appear only once
        XCTAssertEqual(
            updated.sourceApps.filter { $0 == "Safari" }.count,
            1,
            "Should not duplicate app entries"
        )
    }

    // MARK: - WordChange Equatable

    func testWordChange_equatable() {
        let change1 = WordChange(type: .replacement, original: "a", corrected: "b")
        let change2 = WordChange(type: .replacement, original: "a", corrected: "b")
        XCTAssertEqual(change1, change2)
    }

    func testWordChange_hashable_canBeInSet() {
        let change = WordChange(type: .replacement, original: "x", corrected: "y")
        var set = Set<WordChange>()
        set.insert(change)
        set.insert(change)
        XCTAssertEqual(set.count, 1)
    }

    // MARK: - Split / Merge Change Types

    func testIsLikelyCorrection_split_withCommonPrefix() {
        let change = WordChange(type: .split, original: "cannot", corrected: "can not")
        XCTAssertTrue(
            change.isLikelyCorrection, "Split with shared prefix should be a likely correction"
        )
    }

    func testIsLikelyCorrection_merge_withCommonPrefix() {
        let change = WordChange(type: .merge, original: "can not", corrected: "cannot")
        XCTAssertTrue(
            change.isLikelyCorrection, "Merge with shared prefix should be a likely correction"
        )
    }
}
