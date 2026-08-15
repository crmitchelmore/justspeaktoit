import Foundation
import XCTest

@testable import SpeakCore

/// Conformance tests for `FinalizingStreamingTranscriptionClient`.
///
/// Every conformer must answer `finishAndWait()` with the **full transcript for
/// the session**, never just the trailing segment: both shared consumers
/// (`SharedClientLiveController` on macOS, `SharedClientLiveTranscriber` on
/// iOS) replace their transcript with the return value, so a conformer that
/// returned a segment would silently truncate the recording.
///
/// Each case drives the client's own receive path with the provider's real
/// event shapes and then finishes. No session is started: `finishAndWait()`
/// must answer with the full transcript on the "socket already gone" path too,
/// which is exactly what a stop after a dropped connection hits.
final class StreamingClientContractTests: XCTestCase {

    // MARK: - Deepgram (segment-shaped finals, v1/listen)

    func testDeepgram_finishAndWaitReturnsFullTranscriptNotTrailingSegment() async {
        // Arrange
        let client = DeepgramLiveClient(apiKey: "k", model: "nova-3")

        // Act: three standalone final segments, as v1/listen streams them.
        client.parseTranscriptResponse(Self.deepgramFinal("Hello there."))
        client.parseTranscriptResponse(Self.deepgramInterim("this is"))
        client.parseTranscriptResponse(Self.deepgramFinal("This is a test."))
        client.parseTranscriptResponse(Self.deepgramFinal("Goodbye."))
        let transcript = await client.finishAndWait()

        // Assert
        XCTAssertEqual(transcript, "Hello there. This is a test. Goodbye.")
    }

    func testDeepgramFlux_finishAndWaitFoldsEveryTurnIntoOneTranscript() async {
        // Arrange: Flux emits Update/EndOfTurn events on v2/listen.
        let client = DeepgramLiveClient(apiKey: "k", model: "flux-general-en")

        // Act
        client.parseTranscriptResponse(#"{"event":"Update","transcript":"Hello"}"#)
        client.parseTranscriptResponse(#"{"event":"EndOfTurn","transcript":"Hello there."}"#)
        client.parseTranscriptResponse(#"{"event":"EndOfTurn","transcript":"Second turn."}"#)
        let transcript = await client.finishAndWait()

        // Assert
        XCTAssertEqual(transcript, "Hello there. Second turn.")
    }

    func testDeepgram_finishAndWaitWithoutAnySpeechReturnsNil() async {
        // Arrange
        let client = DeepgramLiveClient(apiKey: "k", model: "nova-3")

        // Act
        client.parseTranscriptResponse(Self.deepgramInterim("um"))

        // Assert: interim-only sessions have nothing final to hand back.
        let transcript = await client.finishAndWait()
        XCTAssertNil(transcript)
    }

    func testDeepgram_cumulativeFinalsAreNotDoubled() async {
        // Arrange: a provider that resends the whole utterance must not be
        // concatenated with itself.
        let client = DeepgramLiveClient(apiKey: "k", model: "nova-3")

        // Act
        client.parseTranscriptResponse(Self.deepgramFinal("Hello"))
        client.parseTranscriptResponse(Self.deepgramFinal("Hello there"))
        let transcript = await client.finishAndWait()

        // Assert
        XCTAssertEqual(transcript, "Hello there")
    }

    // MARK: - ElevenLabs (segment-shaped finals)

    func testElevenLabs_finishAndWaitReturnsFullTranscriptNotTrailingSegment() async {
        // Arrange
        let client = ElevenLabsLiveClient(apiKey: "k")

        // Act
        client.parseTranscriptResponse(Self.elevenLabs("Hello there.", isFinal: true))
        client.parseTranscriptResponse(Self.elevenLabs("this is", isFinal: false))
        client.parseTranscriptResponse(Self.elevenLabs("This is a test.", isFinal: true))
        let transcript = await client.finishAndWait()

        // Assert
        XCTAssertEqual(transcript, "Hello there. This is a test.")
    }

    func testElevenLabs_finishAndWaitWithoutAnySpeechReturnsNil() async {
        // Arrange
        let client = ElevenLabsLiveClient(apiKey: "k")

        // Act / Assert
        client.parseTranscriptResponse(Self.elevenLabs("partial", isFinal: false))
        let transcript = await client.finishAndWait()
        XCTAssertNil(transcript)
    }

    // MARK: - xAI (cumulative finals)

    func testXAI_finishAndWaitReturnsFullTranscript() async {
        // Arrange
        let client = XAILiveClient(apiKey: "k")

        // Act: xAI resends the whole turn on every event.
        client.ingest(Self.xai("Hello", type: "updated"))
        client.ingest(Self.xai("Hello there, this is a test.", type: "completed"))
        let transcript = await client.finishAndWait()

        // Assert
        XCTAssertEqual(transcript, "Hello there, this is a test.")
    }

    func testXAI_finishAndWaitWithoutAnySpeechReturnsNil() async {
        // Arrange
        let client = XAILiveClient(apiKey: "k")

        // Act / Assert
        let transcript = await client.finishAndWait()
        XCTAssertNil(transcript)
    }

    // MARK: - Finalisation rule

    /// Issue #641: a short utterance stopped before the provider's first
    /// response. Nothing has been displayed and nothing finalised, so the
    /// transcript strings alone cannot tell "no audio" from "no answer yet" —
    /// the outstanding audio is what forces the bounded wait instead of an
    /// immediate close that loses the words.
    func testFinalisation_WaitsForAudioTheProviderHasNotAnsweredYet() {
        XCTAssertTrue(StreamingFinalisationPolicy.shouldAwaitFinalisation(
            finishFlushesBufferedAudio: false,
            hasUnfinalisedTranscript: false,
            hasUnansweredAudio: true
        ))
    }

    func testFinalisation_ClosesImmediatelyWhenNothingIsOutstanding() {
        XCTAssertFalse(StreamingFinalisationPolicy.shouldAwaitFinalisation(
            finishFlushesBufferedAudio: false,
            hasUnfinalisedTranscript: false,
            hasUnansweredAudio: false
        ))
    }

    func testFinalisation_WaitsForAnUncommittedInterim() {
        XCTAssertTrue(StreamingFinalisationPolicy.shouldAwaitFinalisation(
            finishFlushesBufferedAudio: false,
            hasUnfinalisedTranscript: true,
            hasUnansweredAudio: false
        ))
    }

    /// A finish that flushes buffered audio (Deepgram's `CloseStream`) can
    /// always still yield words, so it drains regardless.
    func testFinalisation_AlwaysDrainsAProviderWhoseFinishFlushesAudio() {
        XCTAssertTrue(StreamingFinalisationPolicy.shouldAwaitFinalisation(
            finishFlushesBufferedAudio: true,
            hasUnfinalisedTranscript: false,
            hasUnansweredAudio: false
        ))
    }

    // MARK: - Accumulator rule

    func testTranscriptAccumulator_mergesSegmentAndCumulativeFinals() {
        // Arrange
        var accumulator = TranscriptAccumulator()

        // Act / Assert: segments append…
        accumulator.append(final: "Hello there.")
        accumulator.append(final: "Second sentence.")
        XCTAssertEqual(accumulator.text, "Hello there. Second sentence.")

        // …a cumulative resend replaces…
        accumulator.append(final: "Hello there. Second sentence. Third.")
        XCTAssertEqual(accumulator.text, "Hello there. Second sentence. Third.")

        // …blank finals are ignored, and the display view adds the interim.
        accumulator.append(final: "   ")
        XCTAssertEqual(accumulator.text, "Hello there. Second sentence. Third.")
        XCTAssertEqual(
            accumulator.display(withInterim: "and a"),
            "Hello there. Second sentence. Third. and a"
        )

        accumulator.reset()
        XCTAssertTrue(accumulator.isEmpty)
        XCTAssertNil(accumulator.transcriptOrNil)
    }

    // MARK: - Fixtures

    private static func deepgramFinal(_ text: String) -> String {
        #"{"channel":{"alternatives":[{"transcript":"\#(text)"}]},"is_final":true}"#
    }

    private static func deepgramInterim(_ text: String) -> String {
        #"{"channel":{"alternatives":[{"transcript":"\#(text)"}]},"is_final":false}"#
    }

    private static func elevenLabs(_ text: String, isFinal: Bool) -> String {
        let event = isFinal ? "FINAL_TRANSCRIPT" : "PARTIAL_TRANSCRIPT"
        return #"{"speech_event_type":"\#(event)","transcript":"\#(text)"}"#
    }

    private static func xai(_ text: String, type: String) -> String {
        #"{"type":"conversation.item.input_audio_transcription.\#(type)","transcript":"\#(text)"}"#
    }
}
