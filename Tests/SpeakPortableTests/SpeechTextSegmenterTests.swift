import Foundation
import SpeakCore
import XCTest

final class SpeechTextSegmenterTests: XCTestCase {
    private func words(_ text: String) -> [Substring] { text.split(whereSeparator: \.isWhitespace) }

    func testTextWithinTheLimitIsOneTrimmedSegment() {
        XCTAssertEqual(SpeechTextSegmenter.segments("  Hello there.  "), ["Hello there."])
        XCTAssertEqual(SpeechTextSegmenter.segments(" \n\t "), [])
        XCTAssertEqual(SpeechTextSegmenter.segments(""), [])
    }

    func testLongTextBreaksAtSentencesAndKeepsEveryWordInOrder() {
        let sentence = "The quick brown fox jumps over the lazy dog. "
        let text = String(repeating: sentence, count: 120)
        let segments = SpeechTextSegmenter.segments(text)
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { $0.unicodeScalars.count <= DeepgramSpeechRequest.maximumCharacters })
        XCTAssertTrue(segments.allSatisfy { $0.hasSuffix(".") }, "segments end at sentence boundaries")
        XCTAssertEqual(words(segments.joined(separator: " ")), words(text))
    }

    func testAnOverlongSentenceBreaksAtWhitespaceThenInsideAWord() {
        let text = "alpha beta gamma delta epsilon"
        let segments = SpeechTextSegmenter.segments(text, limit: 12)
        XCTAssertEqual(segments, ["alpha beta", "gamma delta", "epsilon"])
        XCTAssertEqual(SpeechTextSegmenter.segments("abcdefghij", limit: 4), ["abcd", "efgh", "ij"])
    }

    func testGraphemeClustersAreNeverDividedAndScalarsAreCounted() {
        let family = "👩🏽‍💻"
        let scalars = family.unicodeScalars.count
        let text = String(repeating: family, count: 5)
        let segments = SpeechTextSegmenter.segments(text, limit: scalars * 2)
        XCTAssertEqual(segments, [family + family, family + family, family])
        XCTAssertTrue(segments.allSatisfy { $0.unicodeScalars.count <= scalars * 2 })
        let accented = "e\u{301}e\u{301}e\u{301}"
        XCTAssertEqual(SpeechTextSegmenter.segments(accented, limit: 3), ["e\u{301}", "e\u{301}", "e\u{301}"])
    }

    func testNewlinesEndSentencesAndShortSentencesShareASegment() {
        let text = "First line\nSecond line. Third? Yes!"
        XCTAssertEqual(SpeechTextSegmenter.segments(text), ["First line\nSecond line. Third? Yes!"])
        XCTAssertEqual(SpeechTextSegmenter.segments(text, limit: 24), ["First line\nSecond line.", "Third? Yes!"])
    }
}
