#if os(iOS)
import SpeakCore
import XCTest
@testable import SpeakiOSLib

final class LegacyAppleTranscriptAssemblyTests: XCTestCase {
    func testImplicitReset_commitsPreviousTextAndKeepsItsSegments() {
        var assembly = LegacyAppleTranscriptAssembly()
        XCTAssertEqual(assembly.receive(update("hello there friend", confidence: 0.8), terminal: false),
                       "hello there friend")
        XCTAssertEqual(assembly.receive(update("next", confidence: 0.4), terminal: false),
                       "hello there friend next")
        let (segments, confidence) = assembly.finalSegments(fallbackConfidence: nil)
        XCTAssertEqual(segments.map(\.text), ["hello there friend", "next"])
        XCTAssertEqual(confidence ?? 0, 0.6, accuracy: 0.0001)
    }

    func testEmptyTerminalPayload_doesNotEraseUsablePartial() {
        var assembly = LegacyAppleTranscriptAssembly()
        _ = assembly.receive(update("kept words"), terminal: false)
        XCTAssertNil(assembly.receive(update("", isFinal: true), terminal: true))
        XCTAssertEqual(assembly.finalSegments(fallbackConfidence: nil).0.map(\.text), ["kept words"])
    }

    func testRestartAfterFinal_appendsNextTaskToCommittedText() {
        var assembly = LegacyAppleTranscriptAssembly()
        XCTAssertEqual(assembly.receive(update("first", isFinal: true), terminal: true), "first")
        assembly.keepLatestSegments()
        assembly.beginNextTask()
        XCTAssertEqual(assembly.receive(update("second"), terminal: false), "first second")
        XCTAssertEqual(assembly.finalSegments(fallbackConfidence: 0.3).0.map(\.text), ["first", "second"])
    }

    func testNoSegmentConfidence_usesFallback() {
        var assembly = LegacyAppleTranscriptAssembly()
        _ = assembly.receive(update("words", confidence: nil), terminal: false)
        XCTAssertEqual(assembly.finalSegments(fallbackConfidence: 0.25).1, 0.25)
    }

    private func update(
        _ text: String, isFinal: Bool = false, confidence: Double? = 0.5
    ) -> LegacyAppleRecognitionUpdate {
        LegacyAppleRecognitionUpdate(
            text: text, isFinal: isFinal,
            segments: text.isEmpty ? [] : [TranscriptionSegment(
                startTime: 0, endTime: 1, text: text, isFinal: true, confidence: confidence
            )],
            confidence: confidence
        )
    }
}
#endif
