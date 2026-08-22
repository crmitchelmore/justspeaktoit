import SpeakCore
import XCTest

@testable import SpeakApp

/// Finalisation and projection tests for issue #713: stop must decode the
/// audio WhisperKit's streaming loop never reached, and partial output must
/// never duplicate the window a decode hypothesis re-covers.
@MainActor
final class WhisperKitLiveFinalisationTests: XCTestCase {
    private enum TestError: Error, Equatable {
        case tail
    }

    // MARK: - Tail decode

    func testSubSecondRecording_returnsTailDecode() async throws {
        let stream = MockWhisperKitStream()
        stream.tailText = " Yes."
        let harness = WhisperKitLiveHarness.make(stream: stream)

        try await harness.startRunning(with: stream)
        XCTAssertTrue(harness.delegate.partials.isEmpty, "Nothing was decoded while streaming")
        await harness.controller.stop()

        XCTAssertEqual(stream.tailRequests, [0], "With nothing confirmed the whole recording is decoded")
        XCTAssertEqual(harness.delegate.finished.map(\.text), ["Yes."])
        XCTAssertTrue(harness.delegate.failures.isEmpty)
        XCTAssertFalse(harness.controller.isRunning)
    }

    func testLongerRecording_keepsPhraseFromFinalBuffer() async throws {
        let stream = MockWhisperKitStream()
        stream.tailText = " how are you"
        let harness = WhisperKitLiveHarness.make(stream: stream)

        try await harness.startRunning(with: stream)
        stream.emit(
            .transcript(
                WhisperKitTranscriptState(
                    confirmedSegments: [whisperKitSegment(0, 2.5, " Hello there")],
                    unconfirmedSegments: [whisperKitSegment(2.5, 3.2, " how")],
                    currentText: ""
                )
            )
        )
        await drainWhisperKitAsyncWork()
        XCTAssertEqual(harness.delegate.partials, ["Hello there how"])

        await harness.controller.stop()

        XCTAssertEqual(stream.tailRequests, [2.5], "The tail starts where the confirmed text ends")
        XCTAssertEqual(harness.delegate.finished.map(\.text), ["Hello there how are you"])
    }

    func testEmptyTailDecode_keepsDisplayedText() async throws {
        let stream = MockWhisperKitStream()
        stream.tailText = " [BLANK_AUDIO] "
        let harness = WhisperKitLiveHarness.make(stream: stream)

        try await harness.startRunning(with: stream)
        stream.emit(
            .transcript(
                WhisperKitTranscriptState(
                    confirmedSegments: [whisperKitSegment(0, 2, " Hello")],
                    unconfirmedSegments: [],
                    currentText: " world"
                )
            )
        )
        await drainWhisperKitAsyncWork()
        await harness.controller.stop()

        XCTAssertEqual(harness.delegate.finished.map(\.text), ["Hello world"])
    }

    func testTailDecodeFailure_keepsDisplayedText() async throws {
        let stream = MockWhisperKitStream()
        stream.tailError = TestError.tail
        let harness = WhisperKitLiveHarness.make(stream: stream)

        try await harness.startRunning(with: stream)
        stream.emit(.transcript(WhisperKitTranscriptState(currentText: " streamed words")))
        await drainWhisperKitAsyncWork()
        await harness.controller.stop()

        XCTAssertEqual(harness.delegate.finished.map(\.text), ["streamed words"])
        XCTAssertTrue(harness.delegate.failures.isEmpty, "A failed tail decode degrades, it does not fail the run")
        XCTAssertFalse(harness.controller.isRunning)
    }

    func testTailDecodeTimeout_keepsDisplayedTextAndCompletesStop() async throws {
        let stream = MockWhisperKitStream()
        let tailGate = TestGate()
        stream.tailGate = tailGate
        stream.tailText = " late words"
        let harness = WhisperKitLiveHarness.make(stream: stream, finalisationTimeout: .milliseconds(50))

        try await harness.startRunning(with: stream)
        stream.emit(.transcript(WhisperKitTranscriptState(currentText: " streamed words")))
        await drainWhisperKitAsyncWork()
        await harness.controller.stop()

        XCTAssertEqual(harness.delegate.finished.map(\.text), ["streamed words"])
        XCTAssertFalse(harness.controller.isRunning)

        // A decode that completes after the deadline must not produce a second
        // outcome or disturb a replacement run.
        try await harness.startRunning(with: stream)
        await tailGate.open()
        await drainWhisperKitAsyncWork()
        XCTAssertEqual(harness.delegate.finished.count, 1)
        XCTAssertTrue(harness.controller.isRunning)
        stream.tailGate = nil
        await harness.controller.stop()
        XCTAssertEqual(harness.delegate.finished.map(\.text), ["streamed words", "late words"])
    }

    // MARK: - Projection

    func testHypothesisRevisingUnconfirmedWindow_neverDuplicatesWords() async throws {
        let stream = MockWhisperKitStream()
        let harness = WhisperKitLiveHarness.make(stream: stream)
        try await harness.startRunning(with: stream)

        let confirmed = [whisperKitSegment(0, 2, " The cat")]
        let unconfirmed = [whisperKitSegment(2, 3, " sat on")]
        for currentText in ["", " sat", " sat on the", " sat on the mat"] {
            stream.emit(
                .transcript(
                    WhisperKitTranscriptState(
                        confirmedSegments: confirmed,
                        unconfirmedSegments: unconfirmed,
                        currentText: currentText
                    )
                )
            )
        }
        await drainWhisperKitAsyncWork()

        XCTAssertEqual(
            harness.delegate.partials,
            ["The cat sat on", "The cat sat", "The cat sat on the", "The cat sat on the mat"]
        )
        for partial in harness.delegate.partials {
            XCTAssertFalse(partial.contains("sat on sat"), "Hypothesis must replace the unconfirmed window: \(partial)")
        }
        await harness.controller.stop()
    }

    func testConfirmationPublishedBeforeUnconfirmedReset_doesNotDuplicate() async throws {
        let stream = MockWhisperKitStream()
        let harness = WhisperKitLiveHarness.make(stream: stream)
        try await harness.startRunning(with: stream)

        // WhisperKit publishes a decode result as three state changes: the
        // hypothesis clears, the confirmed array grows, then the unconfirmed
        // array is replaced. The middle observation holds " sat on" in both.
        let oldConfirmed = [whisperKitSegment(0, 2, " The cat")]
        let oldUnconfirmed = [whisperKitSegment(2, 3, " sat on"), whisperKitSegment(3, 4, " the")]
        let newConfirmed = oldConfirmed + [whisperKitSegment(2, 3, " sat on")]
        let states = [
            WhisperKitTranscriptState(
                confirmedSegments: oldConfirmed,
                unconfirmedSegments: oldUnconfirmed,
                currentText: " sat on the mat"
            ),
            WhisperKitTranscriptState(
                confirmedSegments: oldConfirmed,
                unconfirmedSegments: oldUnconfirmed,
                currentText: ""
            ),
            WhisperKitTranscriptState(
                confirmedSegments: newConfirmed,
                unconfirmedSegments: oldUnconfirmed,
                currentText: ""
            ),
            WhisperKitTranscriptState(
                confirmedSegments: newConfirmed,
                unconfirmedSegments: [whisperKitSegment(3, 4, " the"), whisperKitSegment(4, 5, " mat")],
                currentText: ""
            )
        ]
        for state in states {
            stream.emit(.transcript(state))
        }
        await drainWhisperKitAsyncWork()

        XCTAssertEqual(
            harness.delegate.partials,
            ["The cat sat on the mat", "The cat sat on the", "The cat sat on the mat"]
        )
        await harness.controller.stop()
    }
}
