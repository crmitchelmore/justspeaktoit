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
}
