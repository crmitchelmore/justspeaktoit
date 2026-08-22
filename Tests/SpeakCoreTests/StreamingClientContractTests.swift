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

    func testDeepgram_repeatedIdenticalStandaloneFinalsAreBothKept() async {
        // Issue #700: two legitimate standalone finals with identical text are
        // two utterances, not a resend. Deepgram's is_final results are
        // segment-shaped, so nothing may be inferred from text equality.
        let client = DeepgramLiveClient(apiKey: "k", model: "nova-3")

        client.parseTranscriptResponse(Self.deepgramFinal("Yes."))
        client.parseTranscriptResponse(Self.deepgramFinal("Yes."))
        let transcript = await client.finishAndWait()

        XCTAssertEqual(transcript, "Yes. Yes.")
    }

    func testDeepgram_prefixExtendingStandaloneFinalsAreBothKept() async {
        // A later segment that happens to start with the earlier segment's
        // words is still its own segment; prefix inference must not replace.
        let client = DeepgramLiveClient(apiKey: "k", model: "nova-3")

        client.parseTranscriptResponse(Self.deepgramFinal("Hello"))
        client.parseTranscriptResponse(Self.deepgramFinal("Hello there"))
        let transcript = await client.finishAndWait()

        XCTAssertEqual(transcript, "Hello Hello there")
    }

    func testDeepgram_blankFinalsAreIgnored() async {
        let client = DeepgramLiveClient(apiKey: "k", model: "nova-3")

        client.parseTranscriptResponse(Self.deepgramFinal("Hello."))
        client.parseTranscriptResponse(Self.deepgramFinal("   "))
        let transcript = await client.finishAndWait()

        XCTAssertEqual(transcript, "Hello.")
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

    func testElevenLabs_repeatedIdenticalStandaloneFinalsAreBothKept() async {
        // Issue #700: "Yes." followed by "Yes." is two utterances.
        let client = ElevenLabsLiveClient(apiKey: "k")

        client.parseTranscriptResponse(Self.elevenLabs("Yes.", isFinal: true))
        client.parseTranscriptResponse(Self.elevenLabs("Yes.", isFinal: true))
        let transcript = await client.finishAndWait()

        XCTAssertEqual(transcript, "Yes. Yes.")
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

    // MARK: - xAI bounded finalisation (issue #716)

    func testXAIBoundedSend_withheldCompletion_timesOutWithinTheBudget() async {
        // A transport that never invokes the send completion must not hang the
        // finalisation; the bridge resumes at the shared deadline.
        let started = Date()
        let result = await XAILiveClient.awaitBoundedSend(
            deadline: Date().addingTimeInterval(0.3)
        ) { _ in
            // Completion deliberately withheld.
        }

        guard case .timedOut = result else {
            return XCTFail("Expected timedOut, got \(result)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }

    func testXAIBoundedSend_lateAndDuplicateCompletions_cannotDoubleResume() async {
        let held = HeldCompletion()
        let result = await XAILiveClient.awaitBoundedSend(
            deadline: Date().addingTimeInterval(0.15)
        ) { completion in
            held.store(completion)
        }
        guard case .timedOut = result else {
            return XCTFail("Expected timedOut, got \(result)")
        }

        // A late completion after the timeout — delivered twice, then with an
        // error — must be ignored; a double resume would crash the test run.
        held.invoke(with: nil)
        held.invoke(with: nil)
        held.invoke(with: URLError(.networkConnectionLost))
    }

    func testXAIBoundedSend_promptCompletionsReportTheirResult() async {
        let sent = await XAILiveClient.awaitBoundedSend(
            deadline: Date().addingTimeInterval(5)
        ) { completion in
            completion(nil)
        }
        guard case .sent = sent else {
            return XCTFail("Expected sent, got \(sent)")
        }

        let failed = await XAILiveClient.awaitBoundedSend(
            deadline: Date().addingTimeInterval(5)
        ) { completion in
            completion(URLError(.networkConnectionLost))
        }
        guard case .failed = failed else {
            return XCTFail("Expected failed, got \(failed)")
        }
    }

    func testXAIFinishOutcome_confirmedOnlyWhenAFinalEventArrived() async {
        let confirmed = XAILiveClient(apiKey: "k")
        confirmed.ingest(Self.xai("Hello there.", type: "completed"))
        _ = await confirmed.finishAndWait()
        XCTAssertEqual(confirmed.lastFinishOutcome, .confirmedFinal)

        // An interim-only session hands back its best available text but must
        // not claim a clean final.
        let interimOnly = XAILiveClient(apiKey: "k")
        interimOnly.ingest(Self.xai("Hello", type: "updated"))
        let transcript = await interimOnly.finishAndWait()
        XCTAssertEqual(transcript, "Hello")
        XCTAssertEqual(interimOnly.lastFinishOutcome, .bestAvailable)
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

    // MARK: - Accumulator rule (issue #700)

    func testAccumulator_standaloneShape_appendsEveryFinalIncludingIdenticalText() {
        var accumulator = TranscriptAccumulator(shape: .standaloneSegments)

        accumulator.append(final: "Yes.")
        accumulator.append(final: "Yes.")
        XCTAssertEqual(accumulator.text, "Yes. Yes.")

        // Prefix extension is its own segment, never a replacement.
        accumulator.append(final: "Yes. Absolutely.")
        XCTAssertEqual(accumulator.text, "Yes. Yes. Yes. Absolutely.")

        // Blank finals are ignored; the display view appends the interim.
        accumulator.append(final: "   ")
        XCTAssertEqual(accumulator.text, "Yes. Yes. Yes. Absolutely.")
        XCTAssertEqual(
            accumulator.display(withInterim: "and"),
            "Yes. Yes. Yes. Absolutely. and"
        )

        accumulator.reset()
        XCTAssertTrue(accumulator.isEmpty)
        XCTAssertNil(accumulator.transcriptOrNil)
    }

    func testAccumulator_standaloneShape_dropsRetransmissionsOnlyByEventIdentity() {
        var accumulator = TranscriptAccumulator(shape: .standaloneSegments)

        accumulator.append(final: "Yes.", eventID: "turn-1")
        // A retry of the same provider event must not double the words…
        accumulator.append(final: "Yes.", eventID: "turn-1")
        XCTAssertEqual(accumulator.text, "Yes.")

        // …while a new event with identical text is a genuine repeat.
        accumulator.append(final: "Yes.", eventID: "turn-2")
        XCTAssertEqual(accumulator.text, "Yes. Yes.")

        // Resetting forgets seen identities along with the text.
        accumulator.reset()
        accumulator.append(final: "Yes.", eventID: "turn-1")
        XCTAssertEqual(accumulator.text, "Yes.")
    }

    func testAccumulator_cumulativeShape_replacesIncludingNonPrefixRevisions() {
        var accumulator = TranscriptAccumulator(shape: .cumulativeTranscript)

        accumulator.append(final: "hello there")
        XCTAssertEqual(accumulator.text, "hello there")

        // A cumulative correction that is not a prefix extension (casing and
        // punctuation revised) replaces rather than appending a duplicate.
        accumulator.append(final: "Hello there!")
        XCTAssertEqual(accumulator.text, "Hello there!")

        accumulator.append(final: "Hello there! Second turn.")
        XCTAssertEqual(accumulator.text, "Hello there! Second turn.")

        // A cumulative interim restates the whole transcript and stands alone.
        XCTAssertEqual(
            accumulator.display(withInterim: "Hello there! Second turn. And"),
            "Hello there! Second turn. And"
        )

        // Blank finals are ignored.
        accumulator.append(final: " ")
        XCTAssertEqual(accumulator.text, "Hello there! Second turn.")
    }

    func testEveryStreamingClient_declaresItsDocumentedFinalShape() {
        // The declaration is the contract consumers fold by; pin each one.
        XCTAssertEqual(DeepgramLiveClient(apiKey: "k", model: "nova-3").finalShape, .standaloneSegments)
        XCTAssertEqual(ElevenLabsLiveClient(apiKey: "k").finalShape, .standaloneSegments)
        XCTAssertEqual(GladiaLiveClient(apiKey: "k").finalShape, .standaloneSegments)
        XCTAssertEqual(CartesiaLiveClient(apiKey: "k").finalShape, .standaloneSegments)
        XCTAssertEqual(XAILiveClient(apiKey: "k").finalShape, .cumulativeTranscript)
        XCTAssertEqual(SonioxLiveClient(apiKey: "k").finalShape, .cumulativeTranscript)
        XCTAssertEqual(AssemblyAILiveClient(apiKey: "k").finalShape, .cumulativeTranscript)
        XCTAssertEqual(ModulateLiveClient(apiKey: "k").finalShape, .cumulativeTranscript)
    }

    // MARK: - Fixtures

    /// Thread-safe holder for a send completion captured by a fake transport.
    private final class HeldCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: (@Sendable (Error?) -> Void)?

        func store(_ completion: @escaping @Sendable (Error?) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            self.completion = completion
        }

        func invoke(with error: Error?) {
            let held: (@Sendable (Error?) -> Void)? = {
                lock.lock()
                defer { lock.unlock() }
                return completion
            }()
            held?(error)
        }
    }

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
