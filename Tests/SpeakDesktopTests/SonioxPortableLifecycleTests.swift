import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Drives the real shared `SonioxLiveClient` through the injected transport
/// seam. The fake socket, clock and event recorders are the same ones the
/// AssemblyAI, Deepgram and OpenAI lifecycle tests use; only the JSON helpers
/// here are Soniox-shaped. These fake-transport tests exercise framing,
/// admission, ordering and lifecycle only — they are not a live provider,
/// device or performance qualification.
final class SonioxPortableLifecycleTests: XCTestCase {

    // MARK: - Configuration, model and language

    func testConfigFrameCarriesModelSampleRateAndLanguageAfterTheHandshake() throws {
        let fixture = SonioxLiveFixture(model: "stt-rt-v5", language: "fr_FR", sampleRate: 16_000)
        fixture.start()
        let request = fixture.factory.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "wss://stt-rt.soniox.com/transcribe-websocket")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "The key travels in the config frame")
        let socket = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        XCTAssertTrue(socket.controls.isEmpty, "Nothing is sent before the handshake completes")
        XCTAssertTrue(socket.binary.isEmpty)
        socket.open()
        XCTAssertEqual(socket.controls.count, 1, "The configuration frame is the first frame")
        let config = try XCTUnwrap(Self.object(socket.controls[0]))
        XCTAssertEqual(config["api_key"] as? String, "synthetic")
        XCTAssertEqual(config["model"] as? String, "stt-rt-v5")
        XCTAssertEqual(config["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(config["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(config["num_channels"] as? Int, 1)
        XCTAssertEqual(config["language_hints"] as? [String], ["fr"])
        XCTAssertTrue(socket.binary.isEmpty, "Audio waits behind the configuration frame")
        fixture.client.cancel()
    }

    func testAutomaticLanguageOmitsTheLanguageHint() throws {
        let fixture = SonioxLiveFixture(language: nil)
        fixture.start()
        fixture.socket.open()
        let config = try XCTUnwrap(Self.object(fixture.socket.controls[0]))
        XCTAssertNil(config["language_hints"])
        fixture.client.cancel()
    }

    // MARK: - Audio ordering and one-in-flight sends

    func testHandshakeGatesAudioAndConfigPrecedesOneInFlightAudioFrame() {
        let fixture = SonioxLiveFixture()
        fixture.start()
        let socket = fixture.socket
        let first = Data(repeating: 1, count: 3_200)
        let second = Data(repeating: 2, count: 3_200)
        fixture.client.sendAudio(first)
        fixture.client.sendAudio(second)
        XCTAssertTrue(socket.controls.isEmpty)
        XCTAssertTrue(socket.binary.isEmpty)
        socket.open()
        XCTAssertEqual(socket.controls.count, 1, "Config first")
        XCTAssertTrue(socket.binary.isEmpty, "Audio waits for the config send to complete")
        socket.completeSend()
        XCTAssertEqual(socket.binary, [first], "Exactly one audio frame is in flight")
        socket.completeSend()
        XCTAssertEqual(socket.binary, [first, second])
        socket.completeSend()
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertTrue(fixture.client.isConnected)
        fixture.client.cancel()
    }

    func testPreConnectionAudioReplaysInCaptureOrderAheadOfLiveFrames() {
        let fixture = SonioxLiveFixture()
        let pre1 = Data(repeating: 1, count: 3_200)
        let pre2 = Data(repeating: 2, count: 3_200)
        let live = Data(repeating: 3, count: 3_200)
        // Captured before start(): parked in the pre-roll buffer.
        fixture.client.sendAudio(pre1)
        fixture.client.sendAudio(pre2)
        XCTAssertEqual(fixture.client.preroll.snapshot.chunkCount, 2)
        fixture.start()
        XCTAssertTrue(fixture.client.preroll.isEmpty, "start() moves the pre-roll into the send queue")
        let socket = fixture.socket
        socket.open()
        socket.completeSend() // config
        XCTAssertEqual(socket.binary, [pre1], "Replay begins with the earliest captured chunk")
        socket.completeSend()
        XCTAssertEqual(socket.binary, [pre1, pre2])
        socket.completeSend()
        fixture.client.sendAudio(live)
        XCTAssertEqual(socket.binary, [pre1, pre2, live], "Live audio follows the replayed pre-roll in order")
        fixture.client.cancel()
    }

    func testQueuedAndInFlightPCMShareABoundedBudgetAndOverflowFailsOnce() {
        let fixture = SonioxLiveFixture()
        fixture.start()
        let socket = fixture.socket
        socket.open()
        // 5 s of 16 kHz PCM16 == 160,000 bytes exactly fills the budget.
        fixture.client.sendAudio(Data(repeating: 1, count: 160_000))
        fixture.client.sendAudio(Data([1, 2]))
        XCTAssertEqual(fixture.events.errors.count, 1)
        guard case StreamingClientError.transportStalled? = fixture.events.errors.first else {
            return XCTFail("Expected a visible transport stall")
        }
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertFalse(fixture.client.isConnected)
    }

    func testFrameCountIsBoundedBeforeTheHandshake() {
        let fixture = SonioxLiveFixture()
        fixture.start()
        let socket = fixture.socket
        for _ in 0..<(SonioxLiveClient.maximumQueuedFrames + 1) { fixture.client.sendAudio(Data([1, 0])) }
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(socket.cancels, 1)
        socket.open()
        XCTAssertTrue(socket.controls.isEmpty, "A stalled run never handshakes")
    }

    func testOddLengthPCMFailsVisiblyAndInvalidRateAndMissingKeyNeverOpen() {
        let odd = SonioxLiveFixture()
        odd.start()
        odd.becomeReady()
        odd.client.sendAudio(Data([1]))
        XCTAssertEqual(odd.events.errors.first as? SonioxStreamingError, .invalidPCM)
        XCTAssertEqual(odd.socket.cancels, 1)

        let rate = SonioxLiveFixture(sampleRate: 0)
        rate.start()
        XCTAssertTrue(rate.factory.sockets.isEmpty)
        XCTAssertEqual(rate.events.errors.first as? SonioxStreamingError, .invalidSampleRate(0))

        let missing = SonioxLiveFixture(key: " \n")
        missing.start()
        XCTAssertTrue(missing.factory.sockets.isEmpty)
        guard case StreamingClientError.missingAPIKey? = missing.events.errors.first else {
            return XCTFail("Expected a missing-key failure")
        }
    }

    // MARK: - Duplicate / interim final replacement

    func testNonFinalTailReplacesWhileFinalsAccumulateCumulatively() async {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(Self.tokens([(text: "the", final: false)]))
        // A non-final tail is a complete replacement, not an extension.
        socket.emit(Self.tokens([(text: "they", final: false)]))
        socket.emit(Self.tokens([(text: "they ", final: true), (text: "are", final: false)]))
        socket.emit(Self.tokens([(text: "are ", final: true), (text: "here", final: false)]))
        // A final with text identical to earlier interim text still accumulates.
        socket.emit(Self.tokens([(text: "here.", final: true)]))
        XCTAssertEqual(
            fixture.events.texts,
            ["the", "they", "they are", "they are here", "they are here."]
        )
        XCTAssertTrue(fixture.events.finals.allSatisfy { $0 == false }, "Streaming updates are interim")
        fixture.client.cancel()
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "they are here.")
    }

    // MARK: - Awaiting the final after stop

    func testFinishDrainsAudioSendsEndOfStreamThenReturnsTheWholeTranscriptOnce() async {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(Self.tokens([(text: "Hello ", final: true), (text: "world", final: false)]))
        fixture.client.sendAudio(Data(repeating: 7, count: 3_200))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.binary.count == 1 }
        XCTAssertEqual(socket.binary.count, 1, "The queued audio drains before end-of-stream")
        socket.completeSend()
        await fixture.settle { socket.binary.count == 2 }
        XCTAssertEqual(socket.binary.last, Data(), "The end-of-stream frame is empty")
        socket.completeSend()
        // Finalised tail arrives during the silent finish, then the finished frame.
        socket.emit(Self.tokens([(text: "world.", final: true)]))
        socket.emit(Self.finished())
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Hello world.")
        XCTAssertEqual(fixture.events.texts, ["Hello world"], "The trailing final is returned once, not redelivered")
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testGracefulStopDeliversTheFinalWhileFinishing() {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(Self.tokens([(text: "Final ", final: true), (text: "words", final: false)]))
        fixture.client.stop()
        XCTAssertEqual(socket.binary.last, Data(), "Stop flushes with the end-of-stream frame")
        socket.completeSend()
        socket.emit(Self.tokens([(text: "words.", final: true)]))
        socket.emit(Self.finished())
        XCTAssertEqual(fixture.events.texts, ["Final words", "Final words."])
        XCTAssertEqual(fixture.events.finals, [false, true], "Stop delivers the whole transcript as a final")
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testServerClosingTheStreamAfterEndOfStreamSettlesGracefully() async {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(Self.tokens([(text: "Only final.", final: true)]))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.binary.last == Data() }
        socket.completeSend()
        // The server drops the socket after acknowledging end-of-stream.
        socket.fail()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Only final.")
        XCTAssertTrue(fixture.events.errors.isEmpty, "A close during finishing is not an error")
        XCTAssertEqual(socket.cancels, 1)
    }

    // MARK: - Stopping during connection

    func testStopBeforeReadyKeepsOpeningAudioAndFlushesAfterTheHandshake() async {
        let fixture = SonioxLiveFixture()
        fixture.start()
        let socket = fixture.socket
        let opening = Data(repeating: 42, count: 3_200)
        fixture.client.sendAudio(opening)
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(SonioxLiveClient.finishDeadline)
        XCTAssertTrue(socket.controls.isEmpty, "Nothing is sent until the socket opens")
        socket.open()
        socket.completeSend() // config
        XCTAssertEqual(socket.binary, [opening], "The opening audio survives a stop before ready")
        socket.completeSend()
        XCTAssertEqual(socket.binary.last, Data(), "End-of-stream follows the drained opening audio")
        socket.completeSend()
        socket.emit(Self.tokens([(text: "Opening words.", final: true)]))
        socket.emit(Self.finished())
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Opening words.")
        XCTAssertEqual(fixture.factory.sockets.count, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testStopBeforeReadyFailsVisiblyWhenTheHandshakeNeverArrives() async {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(SonioxLiveClient.finishDeadline)
        fixture.clock.fire(SonioxLiveClient.finishDeadline)
        let transcript = await finish.value
        XCTAssertNil(transcript)
        guard case StreamingClientError.transportStalled? = fixture.events.errors.first else {
            return XCTFail("Expected a visible transport stall")
        }
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    // MARK: - Deadlines

    func testHandshakeAndSendStallsFailWithinTheirScheduledBudgets() {
        let connecting = SonioxLiveFixture()
        connecting.start()
        connecting.clock.fire(SonioxLiveClient.readyDeadline)
        XCTAssertEqual(connecting.events.errors.first as? SonioxStreamingError, .connectionFailed)
        XCTAssertEqual(connecting.socket.cancels, 1)

        let sending = SonioxLiveFixture()
        sending.start()
        sending.becomeReady()
        sending.client.sendAudio(Data(repeating: 0, count: 3_200))
        sending.clock.fire(SonioxLiveClient.sendDeadline)
        guard case StreamingClientError.transportStalled? = sending.events.errors.first else {
            return XCTFail("Expected a visible transport stall")
        }
        XCTAssertEqual(sending.socket.cancels, 1)
    }

    // MARK: - Explicit errors before success

    func testServerErrorFrameFailsTheRunOnceAndRetainsBestAvailableText() async {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(Self.tokens([(text: "Partial.", final: true)]))
        socket.emit(#"{"tokens":[],"error_code":503,"error_type":"service_unavailable","error_message":"boom"}"#)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(fixture.events.errors.first as? SonioxStreamingError, .server(code: 503, message: "boom"))
        XCTAssertEqual(socket.cancels, 1)
        // A late frame after the single failure is ignored.
        socket.emit(Self.tokens([(text: "Late.", final: true)]))
        XCTAssertEqual(fixture.events.errors.count, 1)
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Partial.", "The best available text survives the failure")
    }

    func testUnauthorizedErrorFrameMapsToAnInvalidKeyMessage() {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.emit(#"{"tokens":[],"error_code":401,"error_message":"invalid api key"}"#)
        guard case StreamingClientError.invalidAPIKey? = fixture.events.errors.first else {
            return XCTFail("A 401 error frame should map to an invalid-key message")
        }
    }

    func testMalformedFramesAreIgnoredWithoutFailingTheRun() {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit("not json at all")
        socket.emit(#"{"unexpected":true}"#)
        socket.emit(Self.tokens([(text: "Kept.", final: true)]))
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertTrue(fixture.client.isConnected)
        fixture.client.cancel()
    }

    func testFailureIsPublishedBeforeFinishReturnsAndMayStartAReplacement() async {
        let fixture = SonioxLiveFixture()
        let client = fixture.client
        let errorEntered = expectation(description: "Error callback entered on the provider queue")
        let errorCompleted = expectation(description: "Error delivered and replacement started")
        let prematurelyReturned = expectation(description: "Finish cannot return while delivery is suspended")
        prematurelyReturned.isInverted = true
        let finished = expectation(description: "Finish returns after error delivery")
        let gate = SonioxFinishGate()
        client.start(onTranscript: { _, _ in }, onError: { _ in
            errorEntered.fulfill()
            XCTAssertEqual(gate.release.wait(timeout: .now() + 3), .success)
            client.start(onTranscript: { _, _ in }, onError: { _ in XCTFail("Replacement was failed by old cleanup") })
            gate.markDelivered()
            errorCompleted.fulfill()
        })
        let old = fixture.socket
        old.open()
        old.completeSend() // config
        old.emit(Self.tokens([(text: "Saved.", final: true)]))
        let finishing = expectation(description: "End-of-stream proves the finish waiter is registered")
        old.onSend = { message in if case .binary(let data) = message, data.isEmpty { finishing.fulfill() } }
        let finish = Task {
            let result = await client.finishAndWait()
            if !gate.delivered { prematurelyReturned.fulfill() }
            finished.fulfill()
            return result
        }
        await fulfillment(of: [finishing], timeout: 2)
        DispatchQueue.global().async { old.fail() }
        await fulfillment(of: [errorEntered], timeout: 2)
        await fulfillment(of: [prematurelyReturned], timeout: 0.1)
        gate.release.signal()
        await fulfillment(of: [errorCompleted, finished], timeout: 2)
        let result = await finish.value
        XCTAssertEqual(result, "Saved.")
        XCTAssertEqual(old.cancels, 1)
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        let replacement = fixture.factory.sockets[1]
        replacement.open()
        replacement.completeSend()
        replacement.emit(Self.tokens([(text: "Fresh", final: false)]))
        XCTAssertEqual(replacement.cancels, 0)
        client.cancel()
    }

    // MARK: - Late callbacks and reused sessions

    func testOldOpenReceiveSendAndDeadlineCannotMutateTheReplacementSession() {
        let fixture = SonioxLiveFixture()
        fixture.start()
        let old = fixture.socket
        old.open()
        old.completeSend() // config
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        let oldDeadlines = fixture.clock.drain()
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        XCTAssertEqual(old.cancels, 1)
        old.open()
        old.completeSend(URLError(.networkConnectionLost))
        old.emit(Self.tokens([(text: "Stale.", final: true)]))
        oldDeadlines.forEach { $0() }
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertTrue(fixture.events.texts.isEmpty)
        XCTAssertFalse(fixture.client.isConnected)
        replacement.open()
        replacement.completeSend()
        replacement.emit(Self.tokens([(text: "Current", final: false)]))
        fixture.client.sendAudio(Data(repeating: 2, count: 3_200))
        XCTAssertEqual(replacement.binary, [Data(repeating: 2, count: 3_200)])
        XCTAssertEqual(fixture.events.texts, ["Current"])
        XCTAssertTrue(fixture.client.isConnected)
        XCTAssertEqual(fixture.factory.sockets.count, 2, "A stopped run never reconnects")
        fixture.client.cancel()
    }

    func testReusedClientSessionStartsFreshWithoutCarryingTranscript() async {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.emit(Self.tokens([(text: "First.", final: true)]))
        let firstFinish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { fixture.socket.binary.last == Data() }
        fixture.socket.completeSend()
        fixture.socket.emit(Self.finished())
        let first = await firstFinish.value
        XCTAssertEqual(first, "First.")

        fixture.start()
        let second = fixture.factory.sockets[1]
        second.open()
        second.completeSend()
        second.emit(Self.tokens([(text: "Second.", final: true)]))
        let secondFinish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { second.binary.last == Data() }
        second.completeSend()
        second.emit(Self.finished())
        let transcript = await secondFinish.value
        XCTAssertEqual(transcript, "Second.", "The reused client does not carry the first transcript")
    }

    // MARK: - Offline seam

    func testOfflineFullTranscriptAndPrerollContractsRemainCompatible() async {
        let fixture = SonioxLiveFixture()
        // Captured before start(): held in the pre-roll buffer.
        fixture.client.sendAudio(Data([1, 2]))
        XCTAssertEqual(fixture.client.preroll.drain(), [Data([1, 2])])
        // The offline parse seam folds finals into the idle run; finishAndWait
        // returns them even with no socket, exactly as a stop after a dropped
        // connection would.
        fixture.client.ingest(Self.tokens([(text: "Hello ", final: true)]))
        fixture.client.ingest(Self.tokens([(text: "world.", final: true)]))
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Hello world.")
        fixture.client.stop()
        fixture.client.sendAudio(Data([3, 4]))
        XCTAssertTrue(fixture.client.preroll.isEmpty)
    }

    // MARK: - Fixtures

    private static func object(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func tokens(_ tokens: [(text: String, final: Bool)]) -> String {
        let encoded = tokens.map { #"{"text":"\#($0.text)","is_final":\#($0.final)}"# }.joined(separator: ",")
        return #"{"tokens":[\#(encoded)]}"#
    }

    private static func finished() -> String {
        #"{"tokens":[],"final_audio_proc_ms":1560,"total_audio_proc_ms":1680,"finished":true}"#
    }
}

private final class SonioxFinishGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var deliveredValue = false
    var delivered: Bool { lock.withLock { deliveredValue } }
    func markDelivered() { lock.withLock { deliveredValue = true } }
}

/// Builds the shared client over the reusable fake socket/clock/event doubles.
private final class SonioxLiveFixture: @unchecked Sendable {
    let factory = AssemblyAISocketFactory()
    let clock = AssemblyAITestClock()
    let events = AssemblyAITestEvents()
    let client: SonioxLiveClient

    init(key: String = "synthetic", model: String = "stt-rt-v5", language: String? = nil, sampleRate: Int = 16_000) {
        let factory = factory, clock = clock
        client = SonioxLiveClient(
            apiKey: key, model: model, language: language, sampleRate: sampleRate,
            makeConnection: { factory.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
    }

    var socket: AssemblyAITestSocket { factory.sockets[0] }

    func start() {
        client.start(onTranscript: { [events] in events.transcript($0, final: $1) },
                     onError: { [events] in events.fail($0) })
    }

    /// Real handshake plus the configuration send completing, so audio may flow.
    func becomeReady() {
        socket.open()
        socket.completeSend()
    }

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
