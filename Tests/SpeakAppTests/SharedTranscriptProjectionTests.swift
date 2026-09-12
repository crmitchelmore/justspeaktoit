import SpeakCore
@testable import SpeakApp
import XCTest

final class SharedTranscriptProjectionTests: XCTestCase {
    func testWholeSessionSnapshotsReplaceInsteadOfAppendingSegmentFinals() {
        var accumulator = TranscriptAccumulator(shape: .standaloneSegments)

        let first = SharedTranscriptProjection.apply(
            eventText: "First.",
            isFinal: true,
            snapshot: StreamingTranscriptSnapshot(displayText: "First."),
            accumulator: &accumulator
        )
        let second = SharedTranscriptProjection.apply(
            eventText: "Second.",
            isFinal: true,
            snapshot: StreamingTranscriptSnapshot(displayText: "First. Second."),
            accumulator: &accumulator
        )

        XCTAssertEqual(first, "First.")
        XCTAssertEqual(second, "First. Second.")
        XCTAssertEqual(accumulator.text, "First. Second.")
    }

    func testExplicitEmptySnapshotClearsPriorText() {
        var accumulator = TranscriptAccumulator(shape: .standaloneSegments)
        _ = accumulator.append(final: "Prior")

        let result = SharedTranscriptProjection.apply(
            eventText: "ignored",
            isFinal: true,
            snapshot: StreamingTranscriptSnapshot(confirmedText: ""),
            accumulator: &accumulator
        )

        XCTAssertEqual(result, "")
        XCTAssertEqual(accumulator.text, "")
    }
}
