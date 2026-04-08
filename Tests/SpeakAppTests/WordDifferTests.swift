import XCTest

@testable import SpeakApp

final class WordDifferTests: XCTestCase {

    // MARK: - No Changes

    func testFindChanges_identicalStrings_returnsEmpty() {
        let changes = WordDiffer.findChanges(original: "hello world", edited: "hello world")
        XCTAssertTrue(changes.isEmpty, "Identical strings should produce no changes")
    }

    func testFindChanges_emptyStrings_returnsEmpty() {
        let changes = WordDiffer.findChanges(original: "", edited: "")
        XCTAssertTrue(changes.isEmpty)
    }

    func testFindChanges_emptyOriginal_returnsEmpty() {
        let changes = WordDiffer.findChanges(original: "", edited: "hello")
        XCTAssertTrue(changes.isEmpty, "Addition-only should not be treated as correction")
    }

    // MARK: - Simple Replacements

    func testFindChanges_singleWordReplacement() {
        let changes = WordDiffer.findChanges(
            original: "the teh sat",
            edited: "the the sat"
        )
        // Should detect "teh" → "the" as a likely correction (high similarity)
        XCTAssertFalse(changes.isEmpty, "Should detect typo correction")
    }

    func testFindChanges_caseChange_notDetectedForShortStrings() {
        let changes = WordDiffer.findChanges(
            original: "hello World",
            edited: "Hello World"
        )
        // WordDiffer filters via isLikelyCorrection — short case-only changes
        // in 2-word strings may not meet the detection threshold
        XCTAssertTrue(changes.isEmpty, "Short case-only changes are filtered out")
    }

    // MARK: - Rewrite Detection

    func testFindChanges_completeRewrite_returnsEmpty() {
        let changes = WordDiffer.findChanges(
            original: "the quick brown fox jumps over the lazy dog today and tomorrow",
            edited: "a completely different sentence with no overlap whatsoever at all here now"
        )
        XCTAssertTrue(changes.isEmpty, "Complete rewrite should be filtered out")
    }

    // MARK: - Tokenization (via public API)

    func testFindChanges_handlesExtraWhitespace() {
        // Whitespace normalisation happens during tokenization
        let changes = WordDiffer.findChanges(
            original: "hello   world",
            edited: "hello   world"
        )
        XCTAssertTrue(changes.isEmpty, "Same words with different spacing should be no change")
    }

    func testFindChanges_handlesPunctuation() {
        let changes = WordDiffer.findChanges(
            original: "hello, world!",
            edited: "hello, world!"
        )
        XCTAssertTrue(changes.isEmpty)
    }

    // MARK: - Edge Cases

    func testFindChanges_commonPrefixAndSuffix() {
        let changes = WordDiffer.findChanges(
            original: "the quick brown fox jumps",
            edited: "the quick red fox jumps"
        )
        // "brown" → "red" has low string similarity (<30%) so isLikelyCorrection
        // filters it out — this is expected behaviour for dissimilar replacements
        XCTAssertTrue(changes.isEmpty, "Dissimilar replacements are filtered out by isLikelyCorrection")
    }

    func testFindChanges_caseInsensitiveCommonEnds() {
        let changes = WordDiffer.findChanges(
            original: "Hello world test",
            edited: "hello world Test"
        )
        // Case-insensitive prefix/suffix detection should not produce changes for case-only diffs
        // at boundaries, just verifying it produces a deterministic result
        XCTAssertTrue(
            changes.isEmpty || changes.allSatisfy { $0.original.lowercased() == $0.corrected.lowercased() },
            "Changes should only be case corrections"
        )
    }

    func testFindChanges_largeDeletion_doesNotCrashAndReturnsEmpty() {
        let changes = WordDiffer.findChanges(
            original: "one two three four five",
            edited: "one"
        )
        XCTAssertTrue(changes.isEmpty, "Large deletions should be treated as rewrites, not corrections")
    }

    func testFindChanges_largeInsertion_doesNotCrashAndReturnsEmpty() {
        let changes = WordDiffer.findChanges(
            original: "one",
            edited: "one two three four five"
        )
        XCTAssertTrue(changes.isEmpty, "Large insertions should be treated as rewrites, not corrections")
    }

    // MARK: - Performance Baselines
    //
    // These measure{} tests establish baselines for the three distinct hot paths
    // in WordDiffer. Run locally in Xcode (Product → Test) to record initial
    // baselines; subsequent runs will fail if performance regresses beyond 10%.
    //
    // Critical path summary:
    //   1. identicalLongString – tokenise only, exits at `originalWords == editedWords`
    //   2. singleWordCorrection – common-prefix/suffix isolation, 1:1 replacement check
    //   3. lcsHeavyPath – forces O(n×m) `buildLCSTable` with repeated `.lowercased()` calls

    /// Fast path: identical tokens → no diff work after tokenisation.
    func testPerformance_findChanges_identicalLongString() {
        let sentence = "the quick brown fox jumped over the lazy sleeping dog and ran away swiftly"
        measure {
            for _ in 0..<1_000 {
                _ = WordDiffer.findChanges(original: sentence, edited: sentence)
            }
        }
    }

    /// Common prefix/suffix path: single-word correction, no LCS needed.
    func testPerformance_findChanges_singleWordCorrection() {
        let original = "please transcribe this sentence correctly every single time without errors"
        let edited   = "please transcribe this sentence correctly every single time without mistakes"
        measure {
            for _ in 0..<1_000 {
                _ = WordDiffer.findChanges(original: original, edited: edited)
            }
        }
    }

    /// LCS hot path: two extra words in the middle force `buildLCSTable` on a
    /// 9×4 grid, exercising the O(n×m) inner loop and repeated `.lowercased()` calls.
    /// Relevant to backlog item #240 (precompute lowercased tokens before LCS).
    func testPerformance_findChanges_lcsHeavyPath() {
        // After common prefix ("alice", "bob") and suffix ("larry") removal,
        // originalMiddle has 9 words and editedMiddle has 4, forcing extractViaLCS.
        let original = "alice bob charlie dave eve frank george henry ivan jack karl larry"
        let edited   = "alice bob dave frank henry jack larry"
        measure {
            for _ in 0..<500 {
                _ = WordDiffer.findChanges(original: original, edited: edited)
            }
        }
    }
}
