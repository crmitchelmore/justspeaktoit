import Foundation
import XCTest

@testable import SpeakCore

/// Protocol tests for the shared Speechmatics realtime client.
///
/// The client is driven through `ingest` with the frames the `v2` WebSocket API
/// documents, so the parsing, folding, finalisation and error classification are
/// exercised without a socket — which is also the "connection already gone"
/// path a stop after a drop takes.
final class SpeechmaticsLiveClientTests: XCTestCase {

    // MARK: - StartRecognition

    func testStartRecognitionPayload_requestsRawPCM16AndPartials() throws {
        let json = try XCTUnwrap(SpeechmaticsLiveClient.startRecognitionPayload(
            language: "en_GB", accuracyModel: "enhanced", sampleRate: 16_000
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        XCTAssertEqual(object["message"] as? String, "StartRecognition")
        let audio = try XCTUnwrap(object["audio_format"] as? [String: Any])
        XCTAssertEqual(audio["type"] as? String, "raw")
        XCTAssertEqual(audio["encoding"] as? String, "pcm_s16le")
        XCTAssertEqual(audio["sample_rate"] as? Int, 16_000)

        let config = try XCTUnwrap(object["transcription_config"] as? [String: Any])
        XCTAssertEqual(config["language"] as? String, "en")
        // `model` is the current field name; `operating_point` is documented as
        // kept for backward compatibility only.
        XCTAssertEqual(config["model"] as? String, "enhanced")
        XCTAssertNil(config["operating_point"])
        XCTAssertEqual(config["enable_partials"] as? Bool, true)
        XCTAssertEqual(config["max_delay"] as? Double, 0.7)
    }

    func testStartRecognitionPayload_automaticLanguageUsesTheSystemLocale() throws {
        let json = try XCTUnwrap(SpeechmaticsLiveClient.startRecognitionPayload(
            language: nil,
            accuracyModel: "enhanced",
            sampleRate: 16_000,
            systemLocaleIdentifier: "fr_FR"
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let config = try XCTUnwrap(object["transcription_config"] as? [String: Any])

        // Issue #696: a hard-coded `en` transcribes a French speaker with the
        // English model.
        XCTAssertEqual(config["language"] as? String, "fr")
    }

    func testStartRecognitionPayload_blankSystemLocaleFallsBackToEnglish() throws {
        let json = try XCTUnwrap(SpeechmaticsLiveClient.startRecognitionPayload(
            language: nil, accuracyModel: "enhanced", sampleRate: 16_000, systemLocaleIdentifier: ""
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let config = try XCTUnwrap(object["transcription_config"] as? [String: Any])

        XCTAssertEqual(config["language"] as? String, "en")
    }

    func testAccuracyModel_stripsThePrefixAndStreamingSuffix() {
        XCTAssertEqual(
            SpeechmaticsRealtime.accuracyModel(from: "speechmatics/enhanced-streaming"), "enhanced"
        )
        XCTAssertEqual(SpeechmaticsRealtime.accuracyModel(from: "enhanced"), "enhanced")
        XCTAssertEqual(SpeechmaticsRealtime.accuracyModel(from: "  "), "enhanced")
    }

    // MARK: - Transcript folding

    func testFinishAndWait_returnsTheWholeSessionNotTheTrailingSegment() async {
        let client = Self.armedClient()

        client.ingest(Self.final("Hello there.", start: 0, end: 1))
        client.ingest(Self.partial("this is"))
        client.ingest(Self.final("This is a test.", start: 1, end: 2))
        client.ingest(Self.final("Goodbye.", start: 2, end: 3))

        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Hello there. This is a test. Goodbye.")
    }

    func testRepeatedIdenticalFinalsAreBothKept() async {
        // Issue #700: each AddTranscript covers a new span of audio, so two
        // identical finals are two utterances rather than a resend.
        let client = Self.armedClient()

        client.ingest(Self.final("Yes.", start: 0, end: 1))
        client.ingest(Self.final("Yes.", start: 1, end: 2))

        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Yes. Yes.")
    }

    func testEmptyAudioSessionFinishesWithNoTranscript() async {
        let client = Self.armedClient()

        client.ingest(Self.partial("um"))
        client.ingest(Self.final("   ", start: 0, end: 1))

        let transcript = await client.finishAndWait()
        XCTAssertNil(transcript)
    }

    func testTopLevelTranscriptFieldIsAlsoRead() async {
        // The published examples put the text at `metadata.transcript`; the
        // schema table renders it top level. Neither shape may be dropped.
        let client = Self.armedClient()

        client.ingest(#"{"message":"AddTranscript","transcript":"Top level.","results":[]}"#)

        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Top level.")
    }

    func testInterimsAreDeliveredButNeverFolded() async {
        var events: [(String, Bool)] = []
        let client = SpeechmaticsLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { events.append(($0, $1)) }, onError: { _ in })

        client.ingest(Self.partial("hello"))
        client.ingest(Self.final("Hello.", start: 0, end: 1))

        XCTAssertEqual(events.map(\.0), ["hello", "Hello."])
        XCTAssertEqual(events.map(\.1), [false, true])
        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Hello.")
    }

    func testEndOfTranscriptResolvesAnArmedFinishImmediately() async {
        let client = Self.armedClient()
        client.ingest(Self.final("Committed.", start: 0, end: 1))

        let transcript = await client.awaitFinalTranscript(budget: 30) {
            client.ingest(#"{"message":"EndOfTranscript"}"#)
        }

        XCTAssertEqual(transcript, "Committed.")
    }

    func testUnknownFramesNeverEndTheSession() async {
        let client = Self.armedClient()

        client.ingest(#"{"message":"Info","type":"recognition_quality","reason":"quality"}"#)
        client.ingest(#"{"message":"Warning","type":"duration_limit","reason":"limit"}"#)
        client.ingest(#"{"message":"SomethingNewUpstream"}"#)
        client.ingest(Self.final("Still here.", start: 0, end: 1))

        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Still here.")
    }

    // MARK: - Failures

    func testAuthenticationFailureIsReportedAsABadKey() {
        var failure: Error?
        let client = SpeechmaticsLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { failure = $0 })

        client.ingest(#"{"message":"Error","type":"not_authorised","reason":"Not authorised"}"#)

        XCTAssertEqual(failure as? SpeechmaticsRealtimeError, .unauthorized)
    }

    func testQuotaFailureIsNotReportedAsABadKey() {
        // A stored key is never read as entitlement: an exhausted allowance is
        // an account state, not a credential to re-enter.
        var failure: Error?
        let client = SpeechmaticsLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { failure = $0 })

        client.ingest(#"{"message":"Error","type":"quota_exceeded","reason":"No hours left"}"#)

        XCTAssertEqual(
            failure as? SpeechmaticsRealtimeError, .quotaExceeded(message: "No hours left")
        )
    }

    func testUnknownServerErrorKeepsTheProviderReason() {
        var failure: Error?
        let client = SpeechmaticsLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { failure = $0 })

        client.ingest(#"{"message":"Error","type":"job_error","reason":"Internal"}"#)

        XCTAssertEqual(failure as? SpeechmaticsRealtimeError, .server(message: "Internal"))
    }

    func testMissingAPIKeyFailsBeforeAnySocketIsOpened() {
        var failure: Error?
        SpeechmaticsLiveClient(apiKey: "   ").start(onTranscript: { _, _ in }, onError: { failure = $0 })

        guard case .missingAPIKey(let provider)? = failure as? StreamingClientError else {
            return XCTFail("expected a missing-key error, got \(String(describing: failure))")
        }
        XCTAssertEqual(provider, "Speechmatics")
    }

    func testFinishAfterASocketDropStillReturnsWhatWasTranscribed() async {
        // No `RecognitionStarted` and no socket: `EndOfStream` would be
        // rejected, so the client closes rather than burning the budget.
        let client = Self.armedClient()
        client.ingest(Self.final("Partial session.", start: 0, end: 1))

        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Partial session.")
    }

    func testCancellationClearsHeldAudioAndResolvesAWaiter() async {
        let client = SpeechmaticsLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })
        client.sendAudio(Data(repeating: 0, count: 640))
        XCTAssertFalse(client.preroll.isEmpty)

        client.stop()

        XCTAssertTrue(client.preroll.isEmpty)
        let transcript = await client.finishAndWait()
        XCTAssertNil(transcript)
    }

    // MARK: - Audio handling

    func testAudioBeforeRecognitionStartedIsHeldNotDropped() {
        // Issue #641: Speechmatics rejects audio before `RecognitionStarted`,
        // so the user's opening words must survive the handshake.
        let client = SpeechmaticsLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })

        XCTAssertFalse(client.isSessionReady)
        client.sendAudio(Data(repeating: 1, count: 3_200))
        client.sendAudio(Data(repeating: 2, count: 3_200))

        XCTAssertEqual(client.preroll.snapshot.chunkCount, 2)
        XCTAssertEqual(client.preroll.snapshot.droppedChunkCount, 0)
    }

    func testEmptyAudioChunksAreNotBuffered() {
        let client = SpeechmaticsLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })

        client.sendAudio(Data())

        XCTAssertTrue(client.preroll.isEmpty)
    }

    func testTrailingChunkIsPaddedToTheMinimumFrameSize() {
        // Issues #849 and #949: a short tail below the minimum frame size is
        // padded rather than dropped, so the last words still reach the service.
        let short = Data(repeating: 7, count: 100)
        let padded = SpeechmaticsLiveClient.paddedFinalChunk(short)

        XCTAssertEqual(padded.count, SpeechmaticsRealtime.minimumChunkBytes)
        XCTAssertEqual(padded.prefix(100), short)
        XCTAssertTrue(padded.dropFirst(100).allSatisfy { $0 == 0 })
    }

    func testAFullSizeChunkIsSentUnchanged() {
        let full = Data(repeating: 7, count: SpeechmaticsRealtime.minimumChunkBytes)
        XCTAssertEqual(SpeechmaticsLiveClient.paddedFinalChunk(full), full)
    }

    /// The Critical case: the shared capture path hands over one converted tap
    /// buffer at a time, which at a 44.1 kHz or 48 kHz input rate is well under
    /// the service's 3,200-byte minimum. Sending those straight through had
    /// every ordinary frame rejected, not just the tail.
    func testOutboundFrames_neverEmitsAnUndersizedAddAudioFrame() {
        // 4,096 input frames at 48 kHz become 1,365 frames of 16 kHz PCM16,
        // which is 2,730 bytes — below the minimum.
        let tapChunk = Data(repeating: 3, count: 2_730)
        XCTAssertLessThan(tapChunk.count, SpeechmaticsRealtime.minimumChunkBytes)

        var buffer = Data()
        var sent: [Data] = []
        for _ in 0..<10 {
            let (frames, remainder) = SpeechmaticsLiveClient.outboundFrames(
                appending: tapChunk, to: buffer
            )
            sent += frames
            buffer = remainder
        }

        XCTAssertFalse(sent.isEmpty, "coalesced frames must actually be sent")
        for frame in sent {
            XCTAssertGreaterThanOrEqual(
                frame.count,
                SpeechmaticsRealtime.minimumChunkBytes,
                "every non-terminal frame must meet the provider minimum"
            )
        }
        // Capture order is preserved and nothing is lost: the frames plus the
        // remainder are exactly the audio that went in.
        let reassembled = sent.reduce(into: Data()) { $0.append($1) } + buffer
        XCTAssertEqual(reassembled.count, tapChunk.count * 10)
        XCTAssertTrue(reassembled.allSatisfy { $0 == 3 })
    }

    func testOutboundFrames_holdsAnythingBelowTheMinimumForTheNextChunk() {
        let (frames, remainder) = SpeechmaticsLiveClient.outboundFrames(
            appending: Data(repeating: 1, count: 100), to: Data()
        )
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(remainder.count, 100)
    }

    func testOutboundFrames_emitsAsSoonAsTheMinimumIsReached() {
        let (frames, remainder) = SpeechmaticsLiveClient.outboundFrames(
            appending: Data(repeating: 1, count: SpeechmaticsRealtime.minimumChunkBytes),
            to: Data()
        )
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.count, SpeechmaticsRealtime.minimumChunkBytes)
        XCTAssertTrue(remainder.isEmpty)
    }

    func testEndOfStreamSequenceNumberNeverUnderReportsTheTail() {
        XCTAssertEqual(
            SpeechmaticsLiveClient.endOfStreamLastSequenceNumber(lastAcknowledged: 2, sentFrameCount: 3), 3
        )
        XCTAssertEqual(
            SpeechmaticsLiveClient.endOfStreamLastSequenceNumber(lastAcknowledged: 4, sentFrameCount: 3), 4
        )
        XCTAssertEqual(
            SpeechmaticsLiveClient.endOfStreamLastSequenceNumber(lastAcknowledged: -1, sentFrameCount: 0), 0
        )
    }

    // MARK: - Fixtures

    private static func armedClient() -> SpeechmaticsLiveClient {
        let client = SpeechmaticsLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })
        return client
    }

    private static func final(_ text: String, start: Double, end: Double) -> String {
        """
        {"message":"AddTranscript","format":"2.1",\
        "metadata":{"transcript":"\(text)","start_time":\(start),"end_time":\(end)},\
        "results":[]}
        """
    }

    private static func partial(_ text: String) -> String {
        """
        {"message":"AddPartialTranscript","format":"2.1",\
        "metadata":{"transcript":"\(text)","start_time":0,"end_time":1},"results":[]}
        """
    }
}
