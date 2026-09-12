import XCTest

@testable import SpeakCore

final class TranscriptWordDiffTests: XCTestCase {
    private func kinds(_ tokens: [TranscriptWordDiff.Token]) -> [(String, TranscriptWordDiff.Kind)] {
        tokens.map { ($0.text, $0.kind) }
    }

    func testIdenticalTranscripts_areAllEqual() {
        let tokens = TranscriptWordDiff.diff(reference: "the quick brown fox", candidate: "the quick brown fox")
        XCTAssertEqual(tokens.map(\.kind), Array(repeating: .equal, count: 4))
        XCTAssertEqual(tokens.map(\.text), ["the", "quick", "brown", "fox"])
    }

    func testInsertionsAndDeletions_areReportedInPlace() {
        let tokens = TranscriptWordDiff.diff(
            reference: "please send the report today",
            candidate: "please send the full report"
        )
        let expected: [(String, TranscriptWordDiff.Kind)] = [
            ("please", .equal), ("send", .equal), ("the", .equal),
            ("full", .inserted), ("report", .equal), ("today", .deleted)
        ]
        XCTAssertEqual(kinds(tokens).map { "\($0.0):\($0.1)" }, expected.map { "\($0.0):\($0.1)" })
    }

    func testCaseAndPunctuation_doNotCountAsDifferences() {
        let tokens = TranscriptWordDiff.diff(reference: "Hello, world.", candidate: "hello world")
        XCTAssertEqual(tokens.map(\.kind), [.equal, .equal])
        XCTAssertEqual(tokens.map(\.text), ["hello", "world"], "The candidate's spelling is what is shown")
    }

    func testDifferenceRate_isEditsOverReferenceLength() {
        XCTAssertEqual(TranscriptWordDiff.differenceRate(reference: "a b c d", candidate: "a b c d"), 0)
        // "b" deleted, "x" inserted, "d" deleted: three edits over four words.
        XCTAssertEqual(TranscriptWordDiff.differenceRate(reference: "a b c d", candidate: "a x c"), 0.75)
        XCTAssertNil(TranscriptWordDiff.differenceRate(reference: "   ", candidate: "anything"))
    }

    func testLargeDivergence_isStillDiffed_unlikeWordDiffer() {
        let reference = "we should ship the compare models feature before the end of the month"
        let candidate = "we could skip the compare model features after the start of next month okay"
        let tokens = TranscriptWordDiff.diff(reference: reference, candidate: candidate)
        XCTAssertTrue(tokens.contains { $0.kind == .inserted })
        XCTAssertTrue(tokens.contains { $0.kind == .deleted })
        XCTAssertEqual(
            tokens.filter { $0.kind != .deleted }.map(\.text),
            TranscriptWordDiff.words(in: candidate),
            "Reading the non-deleted tokens gives back the candidate"
        )
        XCTAssertEqual(
            tokens.filter { $0.kind != .inserted }.map { TranscriptWordDiff.normalize($0.text) },
            TranscriptWordDiff.words(in: reference).map(TranscriptWordDiff.normalize),
            "Reading the non-inserted tokens gives back the reference"
        )
        XCTAssertTrue(WordDiffer.findChanges(original: reference, edited: candidate).isEmpty)
    }

    func testTenThousandWordDiffPreservesBothTranscriptsWithBoundedMemory() {
        let reference = (0..<10_000).map { "a\($0)" }
        let candidate = (0..<10_000).map { "b\($0)" }
        let tokens = TranscriptWordDiff.diff(reference: reference.joined(separator: " "),
                                             candidate: candidate.joined(separator: " "))
        XCTAssertEqual(tokens.filter { $0.kind != .inserted }.map(\.text), reference)
        XCTAssertEqual(tokens.filter { $0.kind != .deleted }.map(\.text), candidate)
        let identical = TranscriptWordDiff.diff(reference: reference.joined(separator: " "),
                                                candidate: reference.joined(separator: " "))
        XCTAssertTrue(identical.allSatisfy { $0.kind == .equal })
    }

    func testEmptyInputs() {
        XCTAssertEqual(TranscriptWordDiff.diff(reference: "", candidate: "").count, 0)
        XCTAssertEqual(
            TranscriptWordDiff.diff(reference: "", candidate: "new words").map(\.kind),
            [.inserted, .inserted]
        )
        XCTAssertEqual(TranscriptWordDiff.diff(reference: "gone", candidate: "").map(\.kind), [.deleted])
    }
}
