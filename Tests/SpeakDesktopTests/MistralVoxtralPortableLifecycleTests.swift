import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// The shared Mistral Voxtral client over a fake transport: request shape,
/// readiness gating, ordered single-in-flight sends, bounded admission,
/// deadlines and per-run isolation.
final class MistralVoxtralPortableLifecycleTests: XCTestCase {
    private typealias Fixture = MistralVoxtralLiveFixture

    func testRequestCarriesTheModelQueryAndTheKeyOnlyInTheBearerHeader() throws {
        let fixture = Fixture(key: "  synthetic \n")
        fixture.start()
        let request = fixture.factory.requests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
        let url = try XCTUnwrap(request.url)
        XCTAssertFalse(url.absoluteString.contains("synthetic"), "The key travels only in the header")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.mistral.ai")
        XCTAssertEqual(components.path, "/v1/audio/transcriptions/realtime")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "model", value: MistralVoxtralRealtime.apiModelID)])
        XCTAssertTrue(fixture.socket.controls.isEmpty, "Nothing is sent before the handshake")
        fixture.client.cancel()
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testConfigurationWaitsForTheHandshakeAndSessionCreatedAndAudioWaitsForItsSend() throws {
        let fixture = Fixture()
        fixture.start()
        let socket = fixture.socket
        let held = (0..<3).map { Fixture.frame($0) }
        held.forEach(fixture.client.sendAudio)
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 3, "Opening words are held, not dropped")
        socket.open()
        XCTAssertTrue(socket.controls.isEmpty, "An open socket is not a created session")
        socket.sessionCreated()
        XCTAssertEqual(socket.controls, [MistralVoxtralLiveClient.sessionUpdateFrame(sampleRate: 16_000)])
        fixture.client.sendAudio(Fixture.frame(3))
        XCTAssertEqual(socket.types, ["session.update"], "Audio waits for the update's send to complete")
        XCTAssertFalse(fixture.client.isSessionReady)
        socket.completeSend()
        XCTAssertTrue(fixture.client.isSessionReady)
        XCTAssertEqual(socket.appendedAudio, [held[0]], "Exactly one frame is in flight")
        for _ in 0..<4 { socket.completeSend() }
        XCTAssertEqual(socket.appendedAudio, held + [Fixture.frame(3)], "Held audio replays in order, byte for byte")
        fixture.client.sendAudio(Fixture.frame(4))
        XCTAssertEqual(socket.appendedAudio.last, Fixture.frame(4), "Live audio leaves once configured, unbatched")
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
    }

    func testSessionUpdateFrameIsTheCanonicalPayloadWithoutALanguageField() throws {
        let frame = MistralVoxtralLiveClient.sessionUpdateFrame(sampleRate: 16_000)
        let sent = try JSONSerialization.jsonObject(with: Data(frame.utf8))
        let canonical = MistralVoxtralLiveClient.sessionUpdatePayload(sampleRate: 16_000)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: sent, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: canonical, options: .sortedKeys))
        XCTAssertFalse(frame.contains("language"))
        let flush = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(MistralVoxtralLiveClient.flushFrame.utf8)))
        XCTAssertEqual((flush as? [String: String])?["type"], "input_audio.flush")
        let end = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(MistralVoxtralLiveClient.endFrame.utf8)))
        XCTAssertEqual((end as? [String: String])?["type"], "input_audio.end")
    }

    func testSessionCreatedBeforeTheHandshakeStillWaitsForTheOpen() {
        let fixture = Fixture()
        fixture.start()
        fixture.client.sendAudio(Fixture.frame(0))
        fixture.socket.sessionCreated()
        XCTAssertTrue(fixture.socket.controls.isEmpty)
        fixture.socket.open()
        XCTAssertEqual(fixture.socket.types, ["session.update"])
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.appendedAudio, [Fixture.frame(0)])
        fixture.client.cancel()
    }

    func testSynchronousCompletionsDrainAHeldQueueWithoutNestingSends() {
        let fixture = Fixture()
        fixture.start()
        let socket = fixture.socket
        let probe = MistralReentrancyProbe()
        socket.onSend = { [weak socket] _ in
            probe.enter()
            socket?.completeSend()
            probe.leave()
        }
        let frames = (0..<200).map { Fixture.frame($0, count: 320) }
        frames.forEach(fixture.client.sendAudio)
        socket.open()
        socket.sessionCreated()
        XCTAssertEqual(socket.appendedAudio, frames)
        XCTAssertEqual(probe.maximumDepth, 1, "Each completion releases the next send from the loop, not from within")
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 0, "Completed sends release their reservations")
        fixture.client.sendAudio(Fixture.frame(200))
        XCTAssertEqual(socket.appendedAudio.count, 201)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
    }

    func testSynchronouslyQueuedReceivesAreHandledWithoutNesting() throws {
        let socket = MistralSynchronousSocket()
        let fragments = (0..<150).map { " word\($0)" }
        let deltas = try fragments.map { fragment -> String in
            let event = ["type": "transcription.text.delta", "text": fragment]
            return try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: event), encoding: .utf8))
        }
        socket.queue([#"{"type":"session.created"}"#] + deltas)
        let events = AssemblyAITestEvents()
        let client = MistralVoxtralLiveClient(
            apiKey: "synthetic", makeConnection: { _ in socket }, schedule: { _, _ in }
        )
        client.start(onTranscript: { events.transcript($0, final: $1) }, onError: { events.fail($0) })
        XCTAssertEqual(socket.receives.maximumDepth, 1, "Queued messages are received in a loop, not recursively")
        XCTAssertEqual(events.texts.count, fragments.count)
        XCTAssertEqual(events.texts.last, fragments.joined().trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(socket.sent, [MistralVoxtralLiveClient.sessionUpdateFrame(sampleRate: 16_000)])
        XCTAssertTrue(client.isSessionReady)
        client.sendAudio(Fixture.frame(0))
        XCTAssertEqual(socket.sent.last, MistralVoxtralLiveClient.appendFrame(for: Fixture.frame(0)))
        XCTAssertEqual(socket.sends.maximumDepth, 1)
        socket.queue([#"{"type":"transcription.text.delta","text":" more"}"#])
        socket.flush()
        XCTAssertEqual(events.texts.last, fragments.joined().trimmingCharacters(in: .whitespaces) + " more")
        XCTAssertTrue(events.errors.isEmpty)
        client.cancel()
    }

    func testLargeChunksSplitAtTheDecodedCapOnSampleBoundaries() {
        // 48 kHz makes the five-second budget larger than one capped frame.
        let fixture = Fixture(sampleRate: 48_000)
        fixture.start()
        fixture.becomeReady()
        let chunk = Fixture.frame(9, count: 400_000)
        fixture.client.sendAudio(chunk)
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 2)
        fixture.socket.completeSend()
        fixture.socket.completeSend()
        let appended = fixture.socket.appendedAudio
        XCTAssertEqual(appended.map(\.count), [MistralVoxtralRealtime.maximumAppendBytes, 137_856])
        XCTAssertEqual(appended.reduce(Data(), +), chunk)
        XCTAssertEqual(
            fixture.socket.controls[1].utf8.count,
            MistralVoxtralLiveClient.appendFrameByteCount(pcmBytes: MistralVoxtralRealtime.maximumAppendBytes),
            "The reservation is the exact encoded size"
        )
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 0)
        XCTAssertEqual(MistralVoxtralLiveClient.appendSlices(of: Data(count: 10), maximumBytes: 3).map(\.count),
                       [2, 2, 2, 2, 2], "An odd cap still splits on whole samples")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
    }

    func testOddLengthPCMFailsVisiblyAndNothingMoreIsSent() {
        let fixture = Fixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Fixture.frame(0))
        fixture.client.sendAudio(Data([1, 2, 3]))
        XCTAssertEqual(fixture.events.errors.first as? MistralRealtimeStreamingError, .invalidPCM)
        XCTAssertEqual(fixture.socket.cancels, 1)
        fixture.socket.completeSend()
        fixture.client.sendAudio(Fixture.frame(1))
        XCTAssertEqual(fixture.socket.appendedAudio, [Fixture.frame(0)], "A misaligned stream is never sent")
        XCTAssertEqual(fixture.events.errors.count, 1)
    }

    func testHeldAndInFlightFramesShareOneEncodedBudgetAndOverflowFailsOnce() {
        let cost = MistralVoxtralLiveClient.appendFrameByteCount(pcmBytes: 3_200)
        let held = Fixture()
        held.start()
        let fit = held.client.maximumBufferedBytes / cost
        XCTAssertGreaterThanOrEqual(fit, 50, "Five seconds of 100 ms frames fit before readiness")
        for index in 0..<fit { held.client.sendAudio(Fixture.frame(index)) }
        XCTAssertTrue(held.events.errors.isEmpty)
        XCTAssertEqual(held.client.bufferedAudioFrames, fit)
        held.client.sendAudio(Fixture.frame(fit))
        held.client.sendAudio(Fixture.frame(fit + 1))
        XCTAssertEqual(held.events.errors.count, 1)
        guard case StreamingClientError.transportStalled? = held.events.errors.first else {
            return XCTFail("Expected a visible transport stall")
        }
        XCTAssertEqual(held.socket.cancels, 1)
        held.socket.open()
        held.socket.sessionCreated()
        XCTAssertTrue(held.socket.controls.isEmpty, "A failed run never sends")

        let ready = Fixture()
        ready.start()
        ready.becomeReady()
        for index in 0..<fit { ready.client.sendAudio(Fixture.frame(index)) }
        XCTAssertEqual(ready.socket.appendedAudio.count, 1)
        ready.client.sendAudio(Fixture.frame(fit))
        XCTAssertEqual(ready.events.errors.count, 1, "The frame in flight counts against the same budget")
    }

    func testTinyFramesAreBoundedByCountAndAHugeChunkIsRefusedBeforeEncoding() {
        let tiny = Fixture()
        tiny.start()
        for _ in 0..<MistralVoxtralLiveClient.maximumBufferedFrames { tiny.client.sendAudio(Data([1, 0])) }
        XCTAssertTrue(tiny.events.errors.isEmpty)
        tiny.client.sendAudio(Data([1, 0]))
        XCTAssertEqual(tiny.events.errors.count, 1)
        XCTAssertEqual(tiny.socket.cancels, 1)

        let hugeBytes = 64 * 1_024 * 1_024
        let cost = MistralVoxtralLiveClient.appendCost(pcmBytes: hugeBytes)
        XCTAssertEqual(cost.frames, 256, "The cost is arithmetic on the length")
        let huge = Fixture()
        huge.start()
        huge.becomeReady()
        huge.client.sendAudio(Data(count: hugeBytes))
        guard case StreamingClientError.transportStalled? = huge.events.errors.first else {
            return XCTFail("Expected an explicit overflow failure")
        }
        XCTAssertEqual(huge.client.bufferedAudioFrames, 0, "Nothing was sliced into the queue")
        XCTAssertTrue(huge.socket.appendedAudio.isEmpty)
    }
}
