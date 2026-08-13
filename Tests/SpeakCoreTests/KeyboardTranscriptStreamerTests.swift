import XCTest

@testable import SpeakCore

final class KeyboardTranscriptStreamerTests: XCTestCase {
    /// Applies edits to a plain string exactly as the keyboard applies them to
    /// `UITextDocumentProxy`, so tests verify real document contents.
    private struct DocumentSimulator {
        private(set) var text = ""

        mutating func apply(_ edit: KeyboardTranscriptEdit) {
            text = String(text.dropLast(edit.deleteCount)) + edit.insertion
        }
    }

    func testFirstHypothesisInsertsWithoutDeleting() {
        var streamer = KeyboardTranscriptStreamer()

        let edit = streamer.update(hypothesis: "hello")

        XCTAssertEqual(edit, KeyboardTranscriptEdit(deleteCount: 0, insertion: "hello"))
        XCTAssertEqual(streamer.insertedText, "hello")
    }

    func testGrowingHypothesesOnlyAppend() {
        var streamer = KeyboardTranscriptStreamer()
        var document = DocumentSimulator()

        for hypothesis in ["hello", "hello world", "hello world how", "hello world how are you"] {
            document.apply(streamer.update(hypothesis: hypothesis))
        }

        XCTAssertEqual(document.text, "hello world how are you")
        XCTAssertEqual(streamer.insertedText, document.text)
    }

    func testTailRevisionReplacesOnlyTheDivergentSuffix() {
        var streamer = KeyboardTranscriptStreamer()
        var document = DocumentSimulator()

        document.apply(streamer.update(hypothesis: "I want to"))
        let edit = streamer.update(hypothesis: "I want two apples")
        document.apply(edit)

        XCTAssertEqual(edit.deleteCount, 1)
        XCTAssertEqual(edit.insertion, "wo apples")
        XCTAssertEqual(document.text, "I want two apples")
    }

    func testStableWordsArePromotedAndNeverRewritten() {
        var streamer = KeyboardTranscriptStreamer()

        _ = streamer.update(hypothesis: "the quick brown")
        _ = streamer.update(hypothesis: "the quick brown fox")

        // "the quick " survived one revision minus the two-word holdback.
        XCTAssertEqual(streamer.committedText, "the quick ")
        XCTAssertEqual(streamer.volatileTail, "brown fox")
    }

    func testHoldbackKeepsTrailingWordsVolatile() {
        var streamer = KeyboardTranscriptStreamer()

        _ = streamer.update(hypothesis: "hello world")
        _ = streamer.update(hypothesis: "hello world")

        // Two words total; both are within the holdback window.
        XCTAssertEqual(streamer.committedText, "")
        XCTAssertEqual(streamer.volatileTail, "hello world")
    }

    func testDeleteCountNeverExceedsVolatileTail() {
        var streamer = KeyboardTranscriptStreamer()
        var document = DocumentSimulator()

        document.apply(streamer.update(hypothesis: "one two three four five"))
        document.apply(streamer.update(hypothesis: "one two three four five six"))
        let committedLength = streamer.committedText.count

        // A hostile full rewrite may only touch the volatile region.
        let edit = streamer.update(hypothesis: "completely different words")
        XCTAssertLessThanOrEqual(edit.deleteCount, document.text.count - committedLength)
        document.apply(edit)
        XCTAssertTrue(document.text.hasPrefix(streamer.committedText))
    }

    func testRevisionInsideCommittedPrefixSplicesAtWordBoundary() {
        var streamer = KeyboardTranscriptStreamer()
        var document = DocumentSimulator()

        document.apply(streamer.update(hypothesis: "hello world how are"))
        document.apply(streamer.update(hypothesis: "hello world how are you"))
        XCTAssertEqual(streamer.committedText, "hello world how ")

        // The engine revises a committed word; the committed prefix stays and
        // only whole words after the divergence are appended.
        document.apply(streamer.update(hypothesis: "hello word how are you today"))

        XCTAssertTrue(document.text.hasPrefix("hello world how "))
        XCTAssertTrue(document.text.hasSuffix("today"))
        XCTAssertEqual(streamer.insertedText, document.text)
    }

    func testShrunkenHypothesisClearsTailButKeepsCommitted() {
        var streamer = KeyboardTranscriptStreamer()
        var document = DocumentSimulator()

        document.apply(streamer.update(hypothesis: "good morning every"))
        document.apply(streamer.update(hypothesis: "good morning everyone"))
        let committed = streamer.committedText

        document.apply(streamer.update(hypothesis: "good"))

        XCTAssertEqual(streamer.committedText, committed)
        XCTAssertEqual(streamer.volatileTail, "")
        XCTAssertEqual(document.text, committed)
    }

    func testFinalizeCommitsEverythingAndEmitsFinalEdit() {
        var streamer = KeyboardTranscriptStreamer()
        var document = DocumentSimulator()

        document.apply(streamer.update(hypothesis: "send the report"))
        document.apply(streamer.finalize(transcript: "Send the report tomorrow."))

        XCTAssertEqual(streamer.volatileTail, "")
        XCTAssertEqual(streamer.insertedText, streamer.committedText)
        XCTAssertEqual(document.text, streamer.insertedText)
        XCTAssertTrue(document.text.hasSuffix("tomorrow."))
    }

    func testFinalizeWithEmptyTranscriptKeepsPartialText() {
        var streamer = KeyboardTranscriptStreamer()
        var document = DocumentSimulator()

        document.apply(streamer.update(hypothesis: "keep this"))
        let edit = streamer.finalize(transcript: "   ")

        XCTAssertTrue(edit.isNoop)
        XCTAssertEqual(streamer.committedText, "keep this")
        XCTAssertEqual(document.text, "keep this")
    }

    func testResetForgetsStateWithoutEditingDocument() {
        var streamer = KeyboardTranscriptStreamer()

        _ = streamer.update(hypothesis: "some words here")
        streamer.reset()

        XCTAssertEqual(streamer.insertedText, "")
        // A new session must not delete the previous session's text.
        let edit = streamer.update(hypothesis: "fresh start")
        XCTAssertEqual(edit.deleteCount, 0)
    }

    func testIdenticalHypothesisIsNoop() {
        var streamer = KeyboardTranscriptStreamer()

        _ = streamer.update(hypothesis: "same text")
        let edit = streamer.update(hypothesis: "same text")

        XCTAssertTrue(edit.isNoop)
    }

    func testLeadingSeparator() {
        XCTAssertNil(KeyboardTranscriptStreamer.leadingSeparator(contextBeforeInput: nil))
        XCTAssertNil(KeyboardTranscriptStreamer.leadingSeparator(contextBeforeInput: ""))
        XCTAssertNil(KeyboardTranscriptStreamer.leadingSeparator(contextBeforeInput: "line\n"))
        XCTAssertNil(KeyboardTranscriptStreamer.leadingSeparator(contextBeforeInput: "word "))
        XCTAssertEqual(KeyboardTranscriptStreamer.leadingSeparator(contextBeforeInput: "word"), " ")
        XCTAssertEqual(KeyboardTranscriptStreamer.leadingSeparator(contextBeforeInput: "end."), " ")
    }

    // MARK: - Profile post-processing rewrites

    func testReplacingInsertedTextRewritesOnlyTheDivergentSuffix() {
        var streamer = KeyboardTranscriptStreamer()
        var document = DocumentSimulator()

        document.apply(streamer.update(hypothesis: "send the report"))
        document.apply(streamer.finalize(transcript: "send the report tomorow"))

        let edit = streamer.replaceInserted(with: "Send the report tomorrow.")
        document.apply(edit)

        XCTAssertEqual(document.text, "Send the report tomorrow.")
        XCTAssertEqual(streamer.insertedText, "Send the report tomorrow.")
        XCTAssertEqual(streamer.volatileTail, "")
        XCTAssertLessThan(edit.deleteCount, "send the report tomorow".count)
    }

    func testReplacementNeverDeletesMoreThanTheStreamerInserted() {
        var streamer = KeyboardTranscriptStreamer()
        var document = DocumentSimulator()
        document.apply(KeyboardTranscriptEdit(deleteCount: 0, insertion: "host text "))

        document.apply(streamer.update(hypothesis: "dictated words"))
        let edit = streamer.replaceInserted(with: "Completely different wording.")

        XCTAssertLessThanOrEqual(edit.deleteCount, "dictated words".count)
        document.apply(edit)
        XCTAssertEqual(document.text, "host text Completely different wording.")
    }

    func testIdenticalReplacementIsNoop() {
        var streamer = KeyboardTranscriptStreamer()

        _ = streamer.update(hypothesis: "already clean")
        let edit = streamer.replaceInserted(with: "already clean")

        XCTAssertTrue(edit.isNoop)
        XCTAssertEqual(streamer.insertedText, "already clean")
    }

    func testGraphemeClustersAreCountedAsUserPerceivedCharacters() {
        var streamer = KeyboardTranscriptStreamer()
        var document = DocumentSimulator()

        document.apply(streamer.update(hypothesis: "family 👨‍👩‍👧‍👦"))
        let edit = streamer.update(hypothesis: "family 🎉")

        XCTAssertEqual(edit.deleteCount, 1)
        XCTAssertEqual(edit.insertion, "🎉")
        document.apply(edit)
        XCTAssertEqual(document.text, "family 🎉")
    }
}
