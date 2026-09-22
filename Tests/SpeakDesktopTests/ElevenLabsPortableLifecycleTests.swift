import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Drives the real shared `ElevenLabsLiveClient` through the injected transport
/// seam. The fake socket, clock and event recorders are the same doubles the
/// AssemblyAI, Deepgram and OpenAI lifecycle tests use; only the JSON helpers
/// here are ElevenLabs-shaped. A synthetic fixture is not a live-provider,
/// device or performance receipt.
final class ElevenLabsPortableLifecycleTests: XCTestCase {

    // MARK: - Configuration, model and language

    func testCanonicalRequestModelFormatAndLanguageAreSentAndAudioWaitsForSessionStarted() throws {
        let fixture = ElevenLabsFixture(language: "en_GB")
        fixture.start()
        let request = fixture.factory.requests[0]
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.elevenlabs.io")
        XCTAssertEqual(components.path, "/v1/speech-to-text/realtime")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["model_id"], "scribe_v2_realtime")
        XCTAssertEqual(query["audio_format"], "pcm_16000")
        XCTAssertEqual(query["commit_strategy"], "vad")
        XCTAssertEqual(query["language_code"], "en", "A locale is reduced to an ISO-639 language code")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "synthetic")

        let socket = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        socket.open()
        XCTAssertTrue(socket.controls.isEmpty, "Nothing is sent before session_started")
        XCTAssertFalse(fixture.client.isConnected)
        socket.emit(Self.started())
        XCTAssertTrue(fixture.client.isConnected)
        XCTAssertEqual(Self.audioChunks(socket), [Data(repeating: 1, count: 3_200)])
        fixture.client.cancel()
    }

    func testDefaultConfigurationOmitsLanguageCode() throws {
        let fixture = ElevenLabsFixture()
        fixture.start()
        let request = fixture.factory.requests[0]
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let names = (components.queryItems ?? []).map(\.name)
        XCTAssertFalse(names.contains("language_code"))
        fixture.client.cancel()
    }

    // MARK: - Audio ordering and one send in flight

    func testSessionStartedGatesAudioAndOnlyOneChunkIsInFlight() {
        let fixture = ElevenLabsFixture()
        fixture.start()
        let socket = fixture.socket
        let first = Data(repeating: 1, count: 3_200)
        let second = Data(repeating: 2, count: 3_200)
        fixture.client.sendAudio(first)
        fixture.client.sendAudio(second)
        socket.open()
        XCTAssertTrue(socket.controls.isEmpty)
        socket.emit(Self.started())
        XCTAssertEqual(Self.audioChunks(socket), [first], "Exactly one send is in flight")
        socket.completeSend()
        XCTAssertEqual(Self.audioChunks(socket), [first, second])
        socket.completeSend()
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
    }

    // MARK: - Bounded queue overflow

    func testQueuedAndInFlightPCMShareABoundedBudgetAndOverflowFailsOnce() {
        let fixture = ElevenLabsFixture()
        fixture.start()
        let socket = fixture.socket
        socket.open()
        socket.emit(Self.started())
        fixture.client.sendAudio(Data(repeating: 1, count: 160_000))
        fixture.client.sendAudio(Data([1, 2]))
        fixture.client.sendAudio(Data([3, 4]))
        XCTAssertEqual(Self.audioChunks(socket).count, 1)
        XCTAssertEqual(fixture.events.errors.count, 1)
        guard case StreamingClientError.transportStalled? = fixture.events.errors.first else {
            return XCTFail("Expected a visible transport stall on overflow")
        }
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertFalse(fixture.client.isConnected)
    }

    func testSmallChunksAlsoHaveABoundedQueueBeforeReadiness() {
        let fixture = ElevenLabsFixture()
        fixture.start()
        let socket = fixture.socket
        for _ in 0..<257 { fixture.client.sendAudio(Data([1, 0])) }
        XCTAssertTrue(socket.controls.isEmpty)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(socket.cancels, 1)
        socket.open()
        socket.emit(Self.started())
        XCTAssertTrue(socket.controls.isEmpty, "A failed run never sends after the handshake")
    }

    // MARK: - Duplicate / interim final replacement

    func testPartialsReplaceCommittedSegmentsAppendAndIdenticalFinalsAreBothKept() async {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(Self.partial("hel"))
        socket.emit(Self.partial("hello"))
        socket.emit(Self.committed("Hello."))
        socket.emit(Self.committed("Hello."))
        socket.emit(Self.partial("yes"))
        socket.emit(Self.committed("Yes."))
        XCTAssertEqual(fixture.events.texts, ["hel", "hello", "Hello.", "Hello.", "yes", "Yes."])
        XCTAssertEqual(fixture.events.finals, [false, false, true, true, false, true])
        fixture.client.cancel()
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Hello. Hello. Yes.", "Standalone finals append, identical text included")
    }

    // MARK: - Awaiting the trailing final after stop

    func testFinishDrainsAudioCommitsAndReturnsTheTrailingFinalOnce() async {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(Self.committed("Hello."))
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        let finish = Task { await fixture.client.finishAndWait() }
        XCTAssertEqual(Self.audioChunks(socket).count, 1)
        socket.completeSend()
        await fixture.settle { Self.commitCount(socket) == 1 }
        XCTAssertTrue(Self.audioChunks(socket).count == 1, "Only the admitted audio, then the commit")
        socket.completeSend()
        socket.emit(Self.committed("World."))
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Hello. World.")
        XCTAssertEqual(fixture.events.texts, ["Hello."], "The trailing final is returned once, not re-delivered")
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testFinishWithNoTrailingFinalClosesAtTheBudgetWithBestAvailableText() async {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(Self.committed("Only segment."))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { Self.commitCount(socket) == 1 }
        socket.completeSend()
        fixture.clock.fire(ElevenLabsLiveClient.finishBudget)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Only segment.")
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testEmptyFinishReturnsNilAndStillSendsACommit() async {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { Self.commitCount(socket) == 1 }
        socket.completeSend()
        fixture.clock.fire(ElevenLabsLiveClient.finishBudget)
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    // MARK: - Stopping during connection / before readiness

    func testStopBeforeSessionStartedKeepsOpeningAudioAndCommitsAfterReadiness() async {
        let fixture = ElevenLabsFixture()
        fixture.start()
        let socket = fixture.socket
        let opening = Data(repeating: 42, count: 3_200)
        fixture.client.sendAudio(opening)
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(ElevenLabsLiveClient.finishReadyBudget)
        XCTAssertTrue(socket.controls.isEmpty, "Nothing is sent until the session starts")
        socket.open()
        socket.emit(Self.started())
        XCTAssertEqual(Self.audioChunks(socket), [opening])
        socket.completeSend()
        await fixture.settle { Self.commitCount(socket) == 1 }
        socket.completeSend()
        socket.emit(Self.committed("Opening words."))
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Opening words.")
        XCTAssertEqual(fixture.factory.sockets.count, 1)
    }

    func testStopBeforeReadinessFailsVisiblyWhenSessionStartedNeverArrives() async {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.socket.open()
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(ElevenLabsLiveClient.finishReadyBudget)
        fixture.clock.fire(ElevenLabsLiveClient.finishReadyBudget)
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.events.errors.first as? ElevenLabsStreamingError, .sessionNotReady)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    // MARK: - Explicit errors before success, reported once

    func testAuthErrorFailsWithInvalidKeyOnceAndCancels() {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.emit(Self.error("auth_error", "no scribe access"))
        XCTAssertEqual(fixture.events.errors.count, 1)
        guard case StreamingClientError.invalidAPIKey(let provider)? = fixture.events.errors.first else {
            return XCTFail("Expected an invalid-key failure")
        }
        XCTAssertEqual(provider, "ElevenLabs")
        XCTAssertEqual(fixture.socket.cancels, 1)
        fixture.socket.emit(Self.committed("Late."))
        XCTAssertEqual(fixture.events.texts, [], "A failed run delivers nothing further")
    }

    func testTerminalServerErrorFailsOnceWarningIsSurvivedAndUnknownFramesAreIgnored() {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(#"{"message_type":"warning","warning":"clipping"}"#)
        socket.emit(#"{"message_type":"language_detected","language_code":"en"}"#)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertTrue(fixture.client.isConnected, "Warnings and unknown frames leave the session open")
        socket.emit(Self.error("transcriber_error", "model failure"))
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(
            fixture.events.errors.first as? ElevenLabsStreamingError,
            .serverError(type: "transcriber_error", message: "model failure")
        )
        XCTAssertEqual(socket.cancels, 1)
    }

    func testServerErrorWhileAwaitingTheTrailingFinalEndsTheFinishVisibly() async {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(Self.committed("Saved."))
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        socket.completeSend()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { Self.commitCount(socket) == 1 }
        socket.completeSend()
        socket.emit(Self.error("quota_exceeded", "limit reached"))
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Saved.", "The best available text survives the failure")
        XCTAssertEqual(
            fixture.events.errors.first as? ElevenLabsStreamingError,
            .serverError(type: "quota_exceeded", message: "limit reached")
        )
        XCTAssertEqual(socket.cancels, 1)
    }

    func testMissingKeyFailsWithoutCreatingATransport() {
        let fixture = ElevenLabsFixture(key: " \n")
        fixture.start()
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertTrue(fixture.events.errors.first is ElevenLabsLiveError)
    }

    // MARK: - Bounded deadlines

    func testReadinessAndSendStallsFailWithinTheirScheduledBudgets() {
        let connecting = ElevenLabsFixture()
        connecting.start()
        connecting.socket.open()
        connecting.clock.fire(ElevenLabsLiveClient.readyDeadline)
        XCTAssertTrue(connecting.events.errors.first is ElevenLabsLiveError)
        XCTAssertEqual(connecting.socket.cancels, 1)

        let stalled = ElevenLabsFixture()
        stalled.start()
        stalled.becomeReady()
        stalled.client.sendAudio(Data(repeating: 0, count: 3_200))
        stalled.clock.fire(ElevenLabsLiveClient.sendDeadline)
        XCTAssertEqual(stalled.events.errors.count, 1)
        guard case StreamingClientError.transportStalled? = stalled.events.errors.first else {
            return XCTFail("Expected a visible transport stall")
        }
        XCTAssertEqual(stalled.socket.cancels, 1)
    }

    // MARK: - Late callbacks and reused sessions

    func testOldOpenReceiveSendAndDeadlineCannotMutateAReplacementSession() {
        let fixture = ElevenLabsFixture()
        fixture.start()
        let old = fixture.factory.sockets[0]
        old.open()
        old.emit(Self.started())
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        let oldDeadlines = fixture.clock.drain()
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        old.open()
        old.completeSend(URLError(.networkConnectionLost))
        old.emit(Self.committed("Stale."))
        oldDeadlines.forEach { $0() }
        XCTAssertFalse(fixture.client.isConnected)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertTrue(fixture.events.texts.isEmpty)
        XCTAssertEqual(old.cancels, 1)
        replacement.open()
        replacement.emit(Self.started())
        replacement.emit(Self.committed("Current."))
        fixture.client.sendAudio(Data(repeating: 2, count: 3_200))
        XCTAssertEqual(Self.audioChunks(replacement), [Data(repeating: 2, count: 3_200)])
        XCTAssertEqual(fixture.events.texts, ["Current."])
        XCTAssertTrue(fixture.client.isConnected)
        XCTAssertEqual(fixture.factory.sockets.count, 2, "A stopped run never reconnects")
        fixture.client.cancel()
    }

    func testAReusedClientRunsAFreshSessionAfterAGracefulFinish() async {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.emit(Self.committed("First session."))
        fixture.client.stop()
        XCTAssertEqual(fixture.socket.cancels, 1)

        fixture.start()
        let second = fixture.factory.sockets[1]
        second.open()
        second.emit(Self.started())
        second.emit(Self.committed("Second session."))
        fixture.client.sendAudio(Data(repeating: 7, count: 3_200))
        XCTAssertEqual(Self.audioChunks(second).count, 1)
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Second session.", "A reused client starts each session's transcript fresh")
        XCTAssertEqual(fixture.factory.sockets.count, 2)
    }

    // MARK: - Offline seams remain compatible

    func testOfflineFullTranscriptPrerollAndContractFlagsRemainCompatible() async {
        let fixture = ElevenLabsFixture()
        fixture.client.sendAudio(Data([1, 2]))
        XCTAssertEqual(fixture.client.preroll.drain(), [Data([1, 2])])
        XCTAssertEqual(fixture.client.finalShape, .standaloneSegments)
        XCTAssertFalse(fixture.client.finishFlushesBufferedAudio)
        fixture.client.parseTranscriptResponse(Self.committed("Yes."))
        fixture.client.parseTranscriptResponse(Self.committed("Yes."))
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Yes. Yes.")
        fixture.client.stop()
        fixture.client.sendAudio(Data([3, 4]))
        XCTAssertTrue(fixture.client.preroll.isEmpty, "A stopped session buffers nothing further")
    }

    // MARK: - Frame helpers (ElevenLabs realtime shapes)

    private static func started() -> String { #"{"message_type":"session_started","session_id":"s"}"# }
    private static func partial(_ text: String) -> String {
        #"{"message_type":"partial_transcript","text":"\#(text)"}"#
    }
    private static func committed(_ text: String) -> String {
        #"{"message_type":"committed_transcript","text":"\#(text)"}"#
    }
    private static func error(_ type: String, _ message: String) -> String {
        #"{"message_type":"\#(type)","error":"\#(message)"}"#
    }

    private static func audioChunks(_ socket: AssemblyAITestSocket) -> [Data] {
        socket.objects.compactMap { object in
            guard object["message_type"] as? String == "input_audio_chunk",
                  let base64 = object["audio_base_64"] as? String, !base64.isEmpty else { return nil }
            return Data(base64Encoded: base64)
        }
    }

    private static func commitCount(_ socket: AssemblyAITestSocket) -> Int {
        socket.objects.filter { ($0["commit"] as? Bool) == true }.count
    }
}

/// Reuses the shared fake transport, clock and event recorders; only the frames
/// and readiness helper are ElevenLabs-shaped.
private final class ElevenLabsFixture: @unchecked Sendable {
    let factory = AssemblyAISocketFactory()
    let clock = AssemblyAITestClock()
    let events = AssemblyAITestEvents()
    let client: ElevenLabsLiveClient

    init(key: String = "synthetic", language: String? = nil) {
        let factory = factory, clock = clock
        client = ElevenLabsLiveClient(
            apiKey: key, language: language,
            makeConnection: { factory.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
    }

    var socket: AssemblyAITestSocket { factory.sockets[0] }

    func start() {
        client.start(onTranscript: { [events] in events.transcript($0, final: $1) },
                     onError: { [events] in events.fail($0) })
    }

    /// Real handshake, then the server's `session_started` acknowledgement.
    func becomeReady() {
        socket.open()
        socket.emit(#"{"message_type":"session_started"}"#)
    }

    /// Waits until the client has armed a deadline of exactly this length, which
    /// proves an asynchronous wait has registered on the state queue.
    func waitForScheduled(_ seconds: TimeInterval) async {
        for _ in 0..<400 {
            if clock.pending(seconds) > 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("No \(seconds)s deadline was scheduled")
    }

    func settle(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "Condition did not settle")
    }
}
