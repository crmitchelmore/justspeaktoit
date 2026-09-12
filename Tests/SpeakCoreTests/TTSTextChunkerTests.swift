import XCTest
@testable import SpeakCore

/// Long documents reach Soniox as a sequence of requests. The split must stay
/// inside the per-request budget, keep grapheme clusters whole and preserve the
/// reading order, because the parts are spoken back to back.
final class TTSTextChunkerTests: XCTestCase {
    func testShortText_StaysASingleRequest() {
        XCTAssertEqual(TTSTextChunker.chunks("One sentence."), ["One sentence."])
    }

    func testBlankText_ProducesNoRequests() {
        XCTAssertTrue(TTSTextChunker.chunks("   \n\t ").isEmpty)
    }

    func testDefaultBudget_StaysBelowTheAPILimit() {
        XCTAssertLessThan(
            TTSTextChunker.maximumChunkCharacters,
            SonioxTTSAPI.maxTextLength
        )
    }

    func testLongText_IsSplitWithinTheDefaultBudget() {
        let sentence = String(repeating: "This is a sentence about speech. ", count: 400)
        let chunks = TTSTextChunker.chunks(sentence)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= TTSTextChunker.maximumChunkCharacters })
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty })
    }

    func testSplit_PrefersTheEndOfASentence() {
        let text = "First sentence here. Second sentence here. Third sentence here."
        let chunks = TTSTextChunker.chunks(text, maximumCharacters: 30)

        XCTAssertEqual(
            chunks,
            ["First sentence here. ", "Second sentence here. ", "Third sentence here."]
        )
    }

    func testSplit_FallsBackToAWordGapWhenNoSentenceEnds() {
        let chunks = TTSTextChunker.chunks(
            "alpha bravo charlie delta echo",
            maximumCharacters: 12
        )

        XCTAssertEqual(chunks, ["alpha bravo ", "charlie ", "delta echo"])
    }

    func testDecimalPoint_DoesNotEndASentence() {
        let chunks = TTSTextChunker.chunks(
            "The value 3.14159 matters here. Next part.",
            maximumCharacters: 32
        )

        XCTAssertEqual(chunks, ["The value 3.14159 matters here. ", "Next part."])
    }

    func testOrder_IsPreservedWhenTheChunksAreJoined() {
        let text = String(repeating: "Alpha bravo charlie delta. ", count: 500)
        let chunks = TTSTextChunker.chunks(text)

        XCTAssertEqual(
            chunks.joined(),
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func testGraphemeClusters_AreNeverSplit() {
        // Each family emoji is one grapheme cluster built from several scalars,
        // and no word gap exists, so the split falls on a hard boundary.
        let family = "👨‍👩‍👧‍👦"
        let text = String(repeating: family, count: 20)
        let chunks = TTSTextChunker.chunks(text, maximumCharacters: 3)

        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 3 })
        for chunk in chunks {
            XCTAssertTrue(chunk.allSatisfy { String($0) == family })
        }
    }

    func testCombiningMarks_StayWithTheirBaseCharacter() {
        // "e" plus a combining acute accent is a single grapheme cluster.
        let accented = "e\u{0301}"
        let text = String(repeating: accented, count: 12)
        let chunks = TTSTextChunker.chunks(text, maximumCharacters: 5)

        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.unicodeScalars.first != "\u{0301}" })
    }

    func testWordLongerThanTheBudget_IsCutAtTheBudget() {
        let chunks = TTSTextChunker.chunks(
            String(repeating: "a", count: 25),
            maximumCharacters: 10
        )

        XCTAssertEqual(chunks.map(\.count), [10, 10, 5])
    }

    func testZeroBudget_ProducesNoRequestsRatherThanLooping() {
        XCTAssertTrue(TTSTextChunker.chunks("Anything", maximumCharacters: 0).isEmpty)
    }
}
