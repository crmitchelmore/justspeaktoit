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

    // MARK: - Region resolution (never duplicate, never overwrite)

    @MainActor
    func testResolveRegion_MatchesStreamedTextAtAnchor() {
        let state = LiveTextInserter.resolveStreamingRegion(
            fieldText: "before hello world",
            expected: "hello world",
            anchor: 7,
            baselineFieldText: "before "
        )
        XCTAssertEqual(state, .matched(anchor: 7))
    }

    @MainActor
    func testResolveRegion_ReAnchorsWhenTextMovedAndBaselineCannotExplainIt() {
        let state = LiveTextInserter.resolveStreamingRegion(
            fieldText: "typed above\nhello world",
            expected: "hello world",
            anchor: 0,
            baselineFieldText: ""
        )
        XCTAssertEqual(state, .matched(anchor: 12))
    }

    @MainActor
    func testResolveRegion_RefusesReAnchorOntoPreExistingIdenticalText() {
        // The field already contained "foo" before streaming started, so a single
        // remaining "foo" is no proof of where this session's text went.
        let state = LiveTextInserter.resolveStreamingRegion(
            fieldText: "foo",
            expected: "foo",
            anchor: 3,
            baselineFieldText: "foo"
        )
        XCTAssertEqual(state, .unknown)
    }

    @MainActor
    func testResolveRegion_TreatsAlteredStreamedTextAsUnknownNotAbsent() {
        // The app autocorrected the streamed text; declaring it absent would let
        // the standard delivery paste a second copy.
        let state = LiveTextInserter.resolveStreamingRegion(
            fieldText: "Hello world",
            expected: "hello world",
            anchor: 0,
            baselineFieldText: ""
        )
        XCTAssertEqual(state, .unknown)
    }

    @MainActor
    func testResolveRegion_ProvesAbsenceWhenFieldDidNotGrow() {
        // Nothing landed: the field still holds exactly what it held at anchor
        // time, so a single standard delivery is safe.
        let state = LiveTextInserter.resolveStreamingRegion(
            fieldText: "untouched",
            expected: "hello world",
            anchor: 9,
            baselineFieldText: "untouched"
        )
        XCTAssertEqual(state, .absent)
    }

    @MainActor
    func testResolveRegion_ProvesAbsenceForEmptyField() {
        let state = LiveTextInserter.resolveStreamingRegion(
            fieldText: "",
            expected: "hello",
            anchor: 0,
            baselineFieldText: nil
        )
        XCTAssertEqual(state, .absent)
    }

    @MainActor
    func testResolveRegion_WithoutBaselineCannotProveAbsenceInNonEmptyField() {
        let state = LiveTextInserter.resolveStreamingRegion(
            fieldText: "some unrelated content",
            expected: "hello",
            anchor: 0,
            baselineFieldText: nil
        )
        XCTAssertEqual(state, .unknown)
    }

    @MainActor
    func testResolveRegion_DoesNotReAnchorOntoCanonicallyEquivalentText() {
        // "cafe" + combining acute and precomposed "café" render identically but
        // occupy 5 and 4 UTF-16 code units. Matching them would re-anchor the
        // region onto a shorter run and desynchronise every later replacement
        // offset, so anchor search uses exact-scalar (.literal) semantics — the
        // same rule StreamingTextReconciler.diff applies.
        let decomposed = "cafe\u{0301}"
        let precomposed = "caf\u{00E9}"
        XCTAssertEqual(
            LiveTextInserter.resolveStreamingRegion(
                fieldText: "xx \(precomposed)",
                expected: decomposed,
                anchor: 0,
                baselineFieldText: ""
            ),
            .unknown
        )
        XCTAssertTrue(
            LiveTextInserter.utf16Offsets(of: decomposed, in: "xx \(precomposed)", limit: 2).isEmpty
        )
    }

    @MainActor
    func testResolveRegion_AmbiguousOccurrencesAreUnknown() {
        let state = LiveTextInserter.resolveStreamingRegion(
            fieldText: "ab ab",
            expected: "ab",
            anchor: 99,
            baselineFieldText: ""
        )
        XCTAssertEqual(state, .unknown)
    }

    @MainActor
    func testResolveRegion_EmptyExpectedTextOnlyNeedsAnchorInBounds() {
        XCTAssertEqual(
            LiveTextInserter.resolveStreamingRegion(
                fieldText: "hello", expected: "", anchor: 5, baselineFieldText: "hello"
            ),
            .matched(anchor: 5)
        )
        XCTAssertEqual(
            LiveTextInserter.resolveStreamingRegion(
                fieldText: "hello", expected: "", anchor: 6, baselineFieldText: "hello"
            ),
            .unknown
        )
    }
}
