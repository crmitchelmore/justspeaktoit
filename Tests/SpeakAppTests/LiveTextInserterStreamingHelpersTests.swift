import XCTest

@testable import SpeakApp

/// Covers the UTF-16 helpers backing streaming region re-validation, which is
/// what keeps ranged streaming from patching unrelated text (issue #611).
final class LiveTextInserterStreamingHelpersTests: XCTestCase {
    @MainActor
    func testUTF16Substring_ReturnsRegionText() {
        let text = "Hello streamed world"
        XCTAssertEqual(LiveTextInserter.utf16Substring(of: text, location: 6, length: 8), "streamed")
    }

    @MainActor
    func testUTF16Substring_RejectsOutOfBoundsRange() {
        XCTAssertNil(LiveTextInserter.utf16Substring(of: "short", location: 3, length: 10))
        XCTAssertNil(LiveTextInserter.utf16Substring(of: "short", location: -1, length: 2))
    }

    @MainActor
    func testUTF16Substring_RejectsSplitSurrogatePair() {
        let text = "a😀b"
        XCTAssertNil(LiveTextInserter.utf16Substring(of: text, location: 1, length: 1))
        XCTAssertEqual(LiveTextInserter.utf16Substring(of: text, location: 1, length: 2), "😀")
    }

    @MainActor
    func testUTF16Offsets_FindsSingleOccurrence() {
        let offsets = LiveTextInserter.utf16Offsets(of: "streamed", in: "Hello streamed world", limit: 2)
        XCTAssertEqual(offsets, [6])
    }

    @MainActor
    func testUTF16Offsets_UsesUTF16IndicesAfterAstralCharacters() {
        let offsets = LiveTextInserter.utf16Offsets(of: "tail", in: "😀 tail", limit: 2)
        XCTAssertEqual(offsets, [3])
    }

    @MainActor
    func testUTF16Offsets_StopsAtLimitWhenAmbiguous() {
        let offsets = LiveTextInserter.utf16Offsets(of: "ab", in: "ab ab ab", limit: 2)
        XCTAssertEqual(offsets.count, 2)
    }

    @MainActor
    func testUTF16Offsets_ReturnsEmptyWhenAbsent() {
        XCTAssertTrue(LiveTextInserter.utf16Offsets(of: "missing", in: "other text", limit: 2).isEmpty)
        XCTAssertTrue(LiveTextInserter.utf16Offsets(of: "", in: "other text", limit: 2).isEmpty)
    }
}
