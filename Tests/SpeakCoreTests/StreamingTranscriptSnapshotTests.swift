import SpeakCore
import XCTest

final class StreamingTranscriptSnapshotTests: XCTestCase {
    func testDisplayTextIsAuthoritativeEvenWhenEmpty() {
        let snapshot = StreamingTranscriptSnapshot(
            confirmedText: "confirmed",
            pendingInterim: "interim",
            displayText: ""
        )

        XCTAssertEqual(snapshot.resolvedDisplayText, "")
    }

    func testConfirmedAndInterimComposeOnlyWhenDisplayIsAbsent() {
        XCTAssertEqual(
            StreamingTranscriptSnapshot(
                confirmedText: "Confirmed.", pendingInterim: " Pending "
            ).resolvedDisplayText,
            "Confirmed. Pending"
        )
        XCTAssertEqual(
            StreamingTranscriptSnapshot(confirmedText: "").resolvedDisplayText,
            "",
            "an explicit empty confirmation remains an authoritative override"
        )
        XCTAssertNil(StreamingTranscriptSnapshot().resolvedDisplayText)
    }
}
