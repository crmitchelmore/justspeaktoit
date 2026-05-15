import XCTest

@testable import SpeakApp

final class SherpaOnnxTranscriptNormalizerTests: XCTestCase {
    func testNormalize_sentenceCasesUppercaseSherpaOutput() {
        XCTAssertEqual(
            SherpaOnnxTranscriptNormalizer.normalize("HELLO WORLD. THIS IS A LOCAL STREAMING TEST"),
            "Hello world. This is a local streaming test"
        )
    }

    func testNormalize_preservesAlreadyCasedText() {
        XCTAssertEqual(
            SherpaOnnxTranscriptNormalizer.normalize("Hello NASA team"),
            "Hello NASA team"
        )
    }

    func testNormalize_capitalisesStandaloneI() {
        XCTAssertEqual(
            SherpaOnnxTranscriptNormalizer.normalize("I THINK I CAN TEST THIS"),
            "I think I can test this"
        )
    }
}
