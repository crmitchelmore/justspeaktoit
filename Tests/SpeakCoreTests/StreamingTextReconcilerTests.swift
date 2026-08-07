import Foundation
import XCTest
@testable import SpeakCore

final class StreamingTextReconcilerTests: XCTestCase {
    /// Every diff must reconstruct the target when applied to the source.
    private func assertRoundTrip(
        from current: String,
        to target: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> StreamingTextDiff {
        let diff = StreamingTextReconciler.diff(from: current, to: target)
        XCTAssertEqual(
            StreamingTextReconciler.apply(diff, to: current), target,
            "applying diff to source must produce target", file: file, line: line
        )
        return diff
    }

    // MARK: - Prefix growth (appends)

    func testDiff_PureAppendKeepsWholeCurrentAsStablePrefix() {
        let diff = self.assertRoundTrip(from: "hello", to: "hello world")
        XCTAssertEqual(diff.replaceLocationUTF16, 5)
        XCTAssertEqual(diff.replaceLengthUTF16, 0)
        XCTAssertEqual(diff.replacement, " world")
    }

    func testDiff_FirstInsertFromEmptyReplacesNothing() {
        let diff = self.assertRoundTrip(from: "", to: "hello")
        XCTAssertEqual(diff.replaceLocationUTF16, 0)
        XCTAssertEqual(diff.replaceLengthUTF16, 0)
        XCTAssertEqual(diff.replacement, "hello")
    }

    func testDiff_IdenticalSnapshotsAreNoOp() {
        let diff = self.assertRoundTrip(from: "hello world", to: "hello world")
        XCTAssertTrue(diff.isNoOp)
        XCTAssertEqual(diff.replaceLocationUTF16, 11)
    }

    func testDiff_BothEmptyIsNoOp() {
        XCTAssertTrue(self.assertRoundTrip(from: "", to: "").isNoOp)
    }

    // MARK: - Tail retraction

    func testDiff_TargetShorterRetractsTail() {
        let diff = self.assertRoundTrip(from: "hello world", to: "hello")
        XCTAssertEqual(diff.replaceLocationUTF16, 5)
        XCTAssertEqual(diff.replaceLengthUTF16, 6)
        XCTAssertEqual(diff.replacement, "")
    }

    func testDiff_EverythingRetracted() {
        let diff = self.assertRoundTrip(from: "hello", to: "")
        XCTAssertEqual(diff.replaceLocationUTF16, 0)
        XCTAssertEqual(diff.replaceLengthUTF16, 5)
        XCTAssertEqual(diff.replacement, "")
    }

    // MARK: - Corrections rewriting earlier words

    func testDiff_ProviderCorrectionRewritesEarlierWord() {
        // "there" → "their": stable prefix shrinks back to "the"
        let diff = self.assertRoundTrip(
            from: "I think there going home", to: "I think their going home now"
        )
        XCTAssertEqual(diff.replaceLocationUTF16, "I think the".utf16.count)
        XCTAssertEqual(diff.replaceLengthUTF16, "re going home".utf16.count)
        XCTAssertEqual(diff.replacement, "ir going home now")
    }

    func testDiff_CompleteRewriteReplacesEverything() {
        let diff = self.assertRoundTrip(from: "alpha beta", to: "gamma delta")
        XCTAssertEqual(diff.replaceLocationUTF16, 0)
        XCTAssertEqual(diff.replaceLengthUTF16, 10)
        XCTAssertEqual(diff.replacement, "gamma delta")
    }

    func testDiff_MidwordCorrectionOnly() {
        let diff = self.assertRoundTrip(from: "recieve", to: "receive")
        XCTAssertEqual(diff.replaceLocationUTF16, 3)
        XCTAssertEqual(diff.replacement, "eive")
    }

    // MARK: - Unicode / grapheme boundaries

    func testDiff_EmojiAppendKeepsSurrogatePairsIntact() {
        let diff = self.assertRoundTrip(from: "hi 👍", to: "hi 👍🏽 ok")
        // "👍" and "👍🏽" are different grapheme clusters, so the whole cluster is
        // replaced — never split between the base emoji and its modifier.
        XCTAssertEqual(diff.replaceLocationUTF16, 3)
        XCTAssertEqual(diff.replaceLengthUTF16, "👍".utf16.count)
        XCTAssertEqual(diff.replacement, "👍🏽 ok")
    }

    func testDiff_DoesNotSplitFlagsOrZWJSequences() {
        let family = "👨‍👩‍👧‍👦"
        let flag = "🇬🇧"
        let diff = self.assertRoundTrip(from: "go \(family)", to: "go \(flag)")
        XCTAssertEqual(diff.replaceLocationUTF16, 3)
        XCTAssertEqual(diff.replaceLengthUTF16, family.utf16.count)
        XCTAssertEqual(diff.replacement, flag)
    }

    func testDiff_CombiningMarksStayWithBaseCharacter() {
        // "e" + combining acute vs precomposed "é" are canonically equal
        // characters but different scalar sequences; Character comparison
        // treats them as equal, so the prefix may include either form.
        let decomposed = "cafe\u{0301}"
        let precomposed = "caf\u{00E9}"
        let diff = StreamingTextReconciler.diff(from: decomposed, to: precomposed + " bar")
        XCTAssertEqual(
            StreamingTextReconciler.apply(diff, to: decomposed).map { $0 + "" }?.hasSuffix(" bar"),
            true
        )
    }

    func testDiff_UTF16OffsetsAccountForEarlierEmoji() {
        let diff = self.assertRoundTrip(from: "🎉🎉 yes", to: "🎉🎉 yes indeed")
        XCTAssertEqual(diff.replaceLocationUTF16, "🎉🎉 yes".utf16.count) // 4 + 4 for emoji
        XCTAssertEqual(diff.replaceLengthUTF16, 0)
        XCTAssertEqual(diff.replacement, " indeed")
    }

    func testDiff_WhitespaceOnlyChanges() {
        let diff = self.assertRoundTrip(from: "a b", to: "a  b")
        XCTAssertEqual(diff.replaceLocationUTF16, 2)
        XCTAssertEqual(diff.replacement, " b")
    }

    // MARK: - apply() bounds safety

    func testApply_RejectsOutOfBoundsRanges() {
        XCTAssertNil(
            StreamingTextReconciler.apply(
                StreamingTextDiff(replaceLocationUTF16: 4, replaceLengthUTF16: 3, replacement: "x"),
                to: "abc"
            )
        )
        XCTAssertNil(
            StreamingTextReconciler.apply(
                StreamingTextDiff(replaceLocationUTF16: -1, replaceLengthUTF16: 0, replacement: "x"),
                to: "abc"
            )
        )
    }

    func testApply_RejectsRangesSplittingSurrogatePairs() {
        // Location 1 lands mid-surrogate-pair inside "🎉" — must be rejected, not crash.
        XCTAssertNil(
            StreamingTextReconciler.apply(
                StreamingTextDiff(replaceLocationUTF16: 1, replaceLengthUTF16: 1, replacement: "x"),
                to: "🎉"
            )
        )
    }

    // MARK: - Snapshot-sequence simulation

    func testDiff_TypicalProviderSnapshotSequenceReconstructsEachStep() {
        let snapshots = [
            "hel",
            "hello",
            "hello wor",
            "hello world",
            "hello, world",           // punctuation correction rewrites earlier text
            "hello, world how",
            "hello, world — how are", // tail rewritten with em dash
            "hello, world — how are you?"
        ]
        var current = ""
        for snapshot in snapshots {
            let diff = StreamingTextReconciler.diff(from: current, to: snapshot)
            current = StreamingTextReconciler.apply(diff, to: current) ?? "APPLY FAILED"
            XCTAssertEqual(current, snapshot)
        }
    }
}
