import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class SherpaOnnxTranscriptNormalizerTests: XCTestCase {
    private let parakeetModelID = ParakeetLocalModels.tdtV3Int8SourceID
    private let zipformerModelID =
        "local/streaming/huggingface/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26"

    func testNormalize_keepsParakeetAcronyms() {
        XCTAssertEqual(
            SherpaOnnxTranscriptNormalizer.normalize("HTTP API JSON", modelID: parakeetModelID),
            "HTTP API JSON"
        )
    }

    func testNormalize_keepsParakeetNativeSentenceCasing() {
        XCTAssertEqual(
            SherpaOnnxTranscriptNormalizer.normalize(
                "  Ship the JSON to Acme Corp.  ",
                modelID: parakeetModelID
            ),
            "Ship the JSON to Acme Corp."
        )
    }

    func testNormalize_sentenceCasesUppercaseModelsThatLackNativeCasing() {
        XCTAssertEqual(
            SherpaOnnxTranscriptNormalizer.normalize("HELLO WORLD", modelID: zipformerModelID),
            "Hello world"
        )
    }

    func testEmitsNativeCasing_isTrueOnlyForParakeet() {
        XCTAssertTrue(SherpaOnnxTranscriptNormalizer.emitsNativeCasing(modelID: parakeetModelID))
        XCTAssertFalse(SherpaOnnxTranscriptNormalizer.emitsNativeCasing(modelID: zipformerModelID))
        XCTAssertFalse(SherpaOnnxTranscriptNormalizer.emitsNativeCasing(modelID: nil))
    }

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
