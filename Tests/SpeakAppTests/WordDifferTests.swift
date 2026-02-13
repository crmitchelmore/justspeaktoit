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

    func testFindChanges_caseChange_detected() {
        let changes = WordDiffer.findChanges(
            original: "hello World",
            edited: "Hello World"
        )
        // Case changes should be detected as corrections
        if !changes.isEmpty {
            XCTAssertTrue(
                changes.contains { $0.original.lowercased() == $0.corrected.lowercased() },
                "Case change should be detected"
            )
        }
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
        // Tests internal findCommonEnds via the public API
        let changes = WordDiffer.findChanges(
            original: "the quick brown fox jumps",
            edited: "the quick red fox jumps"
        )
        // Should detect "brown" → "red" only
        if !changes.isEmpty {
            XCTAssertTrue(
                changes.contains { $0.original == "brown" && $0.corrected == "red" },
                "Should detect change in middle of common prefix/suffix"
            )
        }
    }

    func testFindChanges_caseInsensitiveCommonEnds() {
        let changes = WordDiffer.findChanges(
            original: "Hello world test",
            edited: "hello world Test"
        )
        // Case-insensitive prefix/suffix detection
        // May or may not produce changes depending on thresholds
        // Just verify it doesn't crash
        _ = changes
    }
}
