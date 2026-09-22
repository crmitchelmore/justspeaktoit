import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

final class OpenAIRealtimePortableLifecycleTests: XCTestCase {
    func testCanonicalRequestAndSessionUpdateFollowTheRealHandshake() throws {
        let fixture = OpenAIRealtimeLiveFixture(language: "en", prompt: "Just Speak to It")
        fixture.start()
        let request = fixture.factory.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "wss://api.openai.com/v1/realtime?intent=transcription")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
        XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Beta"))
        let socket = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 4_800))
        XCTAssertTrue(socket.controls.isEmpty, "Nothing is sent before the handshake completes")
        socket.open()
        XCTAssertEqual(socket.types, ["session.update"])
        let session = try XCTUnwrap(socket.sessionUpdate?["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)
        XCTAssertTrue(input["turn_detection"] is NSNull)
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-live-transcribe")
        XCTAssertEqual(transcription["languages"] as? [String], ["en"])
        XCTAssertNil(transcription["language"])
        XCTAssertEqual(transcription["prompt"] as? String, "Just Speak to It")
        fixture.client.cancel()
    }

    func testSchemaKeepsEachModelFamilyLanguageAndPromptContract() throws {
        let gpt4o = OpenAIRealtimeLiveFixture(
            model: "openai/gpt-4o-transcribe-streaming", language: "en", prompt: "Just Speak to It"
        )
        gpt4o.start()
        gpt4o.socket.open()
        let gpt4oInput = try Self.transcriptionInput(gpt4o.socket)
        XCTAssertEqual(gpt4oInput["model"] as? String, "gpt-4o-transcribe")
        XCTAssertEqual(gpt4oInput["language"] as? String, "en")
        XCTAssertNil(gpt4oInput["languages"])
        XCTAssertEqual(gpt4oInput["prompt"] as? String, "Just Speak to It")
        gpt4o.client.cancel()

        let whisper = OpenAIRealtimeLiveFixture(model: "gpt-realtime-whisper", language: "en", prompt: "Unsupported")
        whisper.start()
        whisper.socket.open()
        let whisperInput = try Self.transcriptionInput(whisper.socket)
        XCTAssertEqual(whisperInput["model"] as? String, "gpt-realtime-whisper")
        XCTAssertEqual(whisperInput["language"] as? String, "en")
        XCTAssertNil(whisperInput["prompt"], "The user prompt is audio context and only supported models get it")
        whisper.client.cancel()
    }

    func testSessionCreatedIsNotReadinessAndAudioWaitsForTheAcknowledgement() {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.startCanonical()
        let socket = fixture.socket
        let first = Data(repeating: 1, count: 4_800)
        let second = Data(repeating: 2, count: 4_800)
        fixture.client.sendAudio(first)
        fixture.client.sendAudio(second)
        socket.open()
        socket.completeSend()
        socket.created()
        XCTAssertFalse(fixture.client.isReady)
        XCTAssertEqual(socket.types, ["session.update"])
        socket.acknowledge()
        XCTAssertTrue(fixture.client.isReady)
        XCTAssertEqual(socket.audio, [first], "Exactly one send is in flight")
        socket.completeSend()
        XCTAssertEqual(socket.audio, [first, second])
        socket.completeSend()
        XCTAssertEqual(fixture.canonical.all, [.sessionCreated, .sessionReady])
        XCTAssertEqual(fixture.client.queuedAudioByteCount, 0)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
    }

    func testAcknowledgementMustFollowOurUpdateAndMatchTheTranscriptionSession() {
        let early = OpenAIRealtimeLiveFixture()
        early.start()
        early.socket.acknowledge()
        XCTAssertFalse(early.client.isReady, "An acknowledgement cannot precede our own session.update")
        early.becomeReady()
        XCTAssertTrue(early.client.isReady)
        early.client.cancel()

        let wrong = OpenAIRealtimeLiveFixture()
        wrong.start()
        wrong.socket.open()
        wrong.socket.completeSend()
        wrong.socket.acknowledge(sessionType: "realtime")
        XCTAssertFalse(wrong.client.isReady)
        XCTAssertEqual(wrong.events.errors.first as? OpenAIRealtimeStreamingError, .unexpectedSessionType("realtime"))
        XCTAssertEqual(wrong.socket.cancels, 1)

        let legacy = OpenAIRealtimeLiveFixture()
        legacy.start()
        legacy.socket.open()
        legacy.socket.completeSend()
        legacy.socket.emit(#"{"type":"transcription_session.updated","session":{"id":"sess_1"}}"#)
        XCTAssertTrue(legacy.client.isReady, "The pre-GA acknowledgement name stays accepted")
        legacy.client.cancel()
    }

    func testPreReadyOverflowIsReportedOnceKeepsTheAdmittedPrefixAndStopsAdmission() {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        let prefix = Data(repeating: 7, count: 240_000 - 4_800)
        let last = Data(repeating: 9, count: 4_800)
        fixture.client.sendAudio(prefix)
        fixture.client.sendAudio(last)
        XCTAssertEqual(fixture.client.queuedAudioByteCount, 240_000)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.sendAudio(Data(repeating: 1, count: 2))
        fixture.client.sendAudio(Data(repeating: 1, count: 4_800))
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(fixture.events.errors.first as? OpenAIRealtimeStreamingError, .audioOverflow)
        XCTAssertEqual(fixture.client.queuedAudioByteCount, 240_000, "Nothing is evicted silently")
        fixture.becomeReady()
        XCTAssertEqual(fixture.socket.audio, [prefix])
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.audio, [prefix, last])
        fixture.socket.completeSend()
        fixture.client.sendAudio(Data(repeating: 3, count: 4_800))
        XCTAssertEqual(fixture.socket.audio.count, 2, "Admission stays closed after the visible gap")
        XCTAssertEqual(fixture.socket.cancels, 0, "The run stays alive to finalise the admitted prefix")
        fixture.client.cancel()
    }

    func testInFlightAudioSharesTheBudgetAndQueuedFrameCountIsBounded() {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Data(repeating: 0, count: 240_000))
        XCTAssertEqual(fixture.socket.audio.count, 1)
        fixture.client.sendAudio(Data([0, 0]))
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(fixture.events.errors.first as? OpenAIRealtimeStreamingError, .audioOverflow)
        fixture.client.cancel()

        let frames = OpenAIRealtimeLiveFixture()
        frames.start()
        for _ in 0...OpenAIRealtimeLiveClient.maximumQueuedFrames { frames.client.sendAudio(Data([1, 0])) }
        XCTAssertEqual(frames.events.errors.count, 1)
        XCTAssertEqual(frames.client.queuedAudioByteCount, OpenAIRealtimeLiveClient.maximumQueuedFrames * 2)
        frames.client.cancel()
    }

    func testUnsupportedSampleRateOddPCMAndMissingKeyFailVisibly() {
        let rate = OpenAIRealtimeLiveFixture(sampleRate: 16_000)
        rate.start()
        XCTAssertTrue(rate.factory.sockets.isEmpty, "Nothing is resampled or sent at the wrong rate")
        XCTAssertEqual(rate.events.errors.first as? OpenAIRealtimeStreamingError, .invalidSampleRate(16_000))

        let odd = OpenAIRealtimeLiveFixture()
        odd.start()
        odd.becomeReady()
        odd.client.sendAudio(Data([1]))
        XCTAssertEqual(odd.events.errors.first as? OpenAIRealtimeStreamingError, .invalidPCM)
        XCTAssertEqual(odd.socket.cancels, 1)

        let missing = OpenAIRealtimeLiveFixture(key: " \n")
        missing.start()
        XCTAssertTrue(missing.factory.sockets.isEmpty)
        XCTAssertEqual(missing.events.errors.first as? OpenAIRealtimeStreamingError, .missingAPIKey)
    }

    func testReadyAndSendDeadlinesFailWithinTheirScheduledBudgets() {
        let connecting = OpenAIRealtimeLiveFixture()
        connecting.start()
        connecting.socket.open()
        connecting.socket.completeSend()
        connecting.socket.created()
        connecting.clock.fire(OpenAIRealtimeLiveClient.readyDeadline)
        XCTAssertEqual(connecting.events.errors.first as? OpenAIRealtimeStreamingError, .sessionNotReady)
        XCTAssertEqual(connecting.socket.cancels, 1)

        let stalled = OpenAIRealtimeLiveFixture()
        stalled.start()
        stalled.becomeReady()
        stalled.client.sendAudio(Data(repeating: 0, count: 4_800))
        stalled.clock.fire(OpenAIRealtimeLiveClient.sendDeadline)
        XCTAssertEqual(stalled.events.errors.count, 1)
        guard case StreamingClientError.transportStalled? = stalled.events.errors.first else {
            return XCTFail("Expected a visible transport stall")
        }
        XCTAssertEqual(stalled.socket.cancels, 1)
    }

    func testOldOpenAcknowledgementSendAndDeadlinesCannotMutateTheReplacement() {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        let old = fixture.socket
        fixture.becomeReady()
        fixture.client.sendAudio(Data(repeating: 1, count: 4_800))
        let oldDeadlines = fixture.clock.drain()
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        XCTAssertEqual(old.cancels, 1)
        old.open()
        old.acknowledge()
        old.completeSend(URLError(.networkConnectionLost))
        old.delta("Stale", item: "old")
        oldDeadlines.forEach { $0() }
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertTrue(fixture.events.texts.isEmpty)
        XCTAssertFalse(fixture.client.isReady)
        replacement.open()
        replacement.completeSend()
        replacement.acknowledge()
        replacement.delta("Current", item: "new")
        fixture.client.sendAudio(Data(repeating: 2, count: 4_800))
        XCTAssertEqual(replacement.audio.count, 1)
        XCTAssertEqual(fixture.events.texts, ["Current"])
        XCTAssertTrue(fixture.client.isReady)
        XCTAssertEqual(fixture.factory.sockets.count, 2, "A stopped run never reconnects")
        fixture.client.cancel()
    }

    func testCanonicalReadinessAndPendingSendWaitsGateTheAppleStopSequence() async {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.startCanonical()
        let socket = fixture.socket
        let prefix = Data(repeating: 1, count: 4_800)
        fixture.client.sendAudio(prefix)
        let timedOut = Task { await fixture.client.awaitSessionReady(timeout: 1) }
        await fixture.waitForScheduled(1)
        fixture.clock.fire(1)
        let readyBeforeAcknowledgement = await timedOut.value
        XCTAssertFalse(readyBeforeAcknowledgement)
        XCTAssertTrue(socket.audio.isEmpty, "The prefix is retained, not dropped, while not ready")
        await fixture.client.awaitPendingSends(timeout: 1.5)
        let ready = Task { await fixture.client.awaitSessionReady(timeout: 1) }
        await fixture.waitForScheduled(1)
        fixture.becomeReady()
        let isReady = await ready.value
        XCTAssertTrue(isReady)
        XCTAssertEqual(socket.audio, [prefix], "The prefix entered the transport before readiness resumed")
        let drained = Task { await fixture.client.awaitPendingSends(timeout: 1.5) }
        await fixture.waitForScheduled(1.5)
        socket.completeSend()
        await drained.value
        fixture.client.commitInputBuffer()
        XCTAssertEqual(socket.types.last, "input_audio_buffer.commit")
        fixture.client.commitInputBuffer()
        socket.completeSend()
        XCTAssertEqual(socket.types.filter { $0 == "input_audio_buffer.commit" }.count, 1,
                       "Nothing new was admitted, so nothing is committed twice")
        XCTAssertEqual(fixture.canonical.all, [.sessionReady])
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
    }

    private static func transcriptionInput(_ socket: AssemblyAITestSocket) throws -> [String: Any] {
        let session = try XCTUnwrap(socket.sessionUpdate?["session"] as? [String: Any])
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        return try XCTUnwrap(input["transcription"] as? [String: Any])
    }
}
