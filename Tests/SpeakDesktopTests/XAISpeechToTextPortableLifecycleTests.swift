import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// The shared xAI dedicated speech-to-text client over a fake transport:
/// request shape, readiness gating, ordered single-in-flight sends, bounded
/// admission, deadlines and per-run isolation.
final class XAISpeechToTextPortableLifecycleTests: XCTestCase {
    func testCanonicalRequestConfiguresTheSessionThroughQueryItemsAndABearerHeader() throws {
        let fixture = XAISpeechToTextLiveFixture(language: "en_GB", keywords: ["Speak", "xAI"])
        fixture.start()
        let request = fixture.factory.requests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
        let url = try XCTUnwrap(request.url)
        XCTAssertFalse(url.absoluteString.contains("synthetic"), "The key travels only in the header")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.x.ai")
        XCTAssertEqual(components.path, "/v1/stt")
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.filter { $0.name == "model" }.map(\.value), ["grok-voice-transcribe-2.0"])
        XCTAssertEqual(items.first { $0.name == "encoding" }?.value, "pcm")
        XCTAssertEqual(items.first { $0.name == "sample_rate" }?.value, "24000")
        XCTAssertEqual(items.first { $0.name == "interim_results" }?.value, "true")
        XCTAssertEqual(items.first { $0.name == "language" }?.value, "en")
        XCTAssertEqual(items.filter { $0.name == "keyterm" }.map(\.value), ["Speak", "xAI"])
        fixture.client.cancel()
    }

    func testOpenIsNotReadinessAndHeldAudioLeavesInOrderAfterTranscriptCreated() {
        let fixture = XAISpeechToTextLiveFixture()
        fixture.start()
        let socket = fixture.socket
        let first = XAISpeechToTextLiveFixture.frame(1)
        let second = XAISpeechToTextLiveFixture.frame(2)
        fixture.client.sendAudio(first)
        socket.open()
        fixture.client.sendAudio(second)
        XCTAssertFalse(fixture.client.isSessionReady)
        XCTAssertTrue(socket.binary.isEmpty, "The service refuses audio before transcript.created")
        socket.transcriptCreated()
        XCTAssertTrue(fixture.client.isSessionReady)
        XCTAssertEqual(socket.binary, [first], "Exactly one send is in flight")
        socket.completeSend()
        XCTAssertEqual(socket.binary, [first, second])
        socket.completeSend()
        fixture.client.sendAudio(XAISpeechToTextLiveFixture.frame(3))
        XCTAssertEqual(socket.binary.count, 3, "Live audio goes straight to the transport once ready")
        XCTAssertTrue(socket.controls.isEmpty, "There is no start message; the query configures the session")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
        XCTAssertEqual(socket.cancels, 1)
    }

    func testQueuedAndInFlightAudioShareOneBoundedBudgetAndOverflowFailsOnce() {
        let connecting = XAISpeechToTextLiveFixture()
        connecting.start()
        connecting.client.sendAudio(XAISpeechToTextLiveFixture.frame(1, count: 240_000))
        XCTAssertTrue(connecting.events.errors.isEmpty, "Five seconds of 24 kHz PCM16 is the budget")
        connecting.client.sendAudio(Data([0, 0]))
        connecting.client.sendAudio(Data([0, 0]))
        XCTAssertEqual(connecting.events.errors.count, 1)
        guard case StreamingClientError.transportStalled? = connecting.events.errors.first else {
            return XCTFail("Expected a visible transport stall")
        }
        XCTAssertEqual(connecting.socket.cancels, 1)
        XCTAssertFalse(connecting.client.isSessionReady)
        connecting.socket.transcriptCreated()
        XCTAssertTrue(connecting.socket.binary.isEmpty, "A failed run never sends")

        let ready = XAISpeechToTextLiveFixture()
        ready.start()
        ready.becomeReady()
        ready.client.sendAudio(XAISpeechToTextLiveFixture.frame(1, count: 240_000))
        XCTAssertEqual(ready.socket.binary.count, 1)
        ready.client.sendAudio(Data([0, 0]))
        XCTAssertEqual(ready.events.errors.count, 1, "In-flight bytes count against the same budget")
        XCTAssertEqual(ready.socket.cancels, 1)
    }

    func testSmallFramesAlsoHaveABoundedQueueBeforeReadiness() {
        let fixture = XAISpeechToTextLiveFixture()
        fixture.start()
        for _ in 0...XAISpeechToTextLiveClient.maximumQueuedFrames { fixture.client.sendAudio(Data([1, 0])) }
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(fixture.socket.cancels, 1)
        fixture.becomeReady()
        XCTAssertTrue(fixture.socket.binary.isEmpty)
    }

    func testMissingKeyAndUnsupportedSampleRateFailWithoutCreatingATransport() {
        let missing = XAISpeechToTextLiveFixture(key: " \n")
        missing.start()
        XCTAssertTrue(missing.factory.sockets.isEmpty)
        XCTAssertEqual(
            missing.events.errors.first?.localizedDescription,
            StreamingClientError.missingAPIKey(provider: "xAI").localizedDescription
        )
        let rate = XAISpeechToTextLiveFixture(sampleRate: 11_025)
        rate.start()
        XCTAssertTrue(rate.factory.sockets.isEmpty, "Nothing is resampled or sent at the wrong rate")
        XCTAssertEqual(rate.events.errors.first as? XAISpeechToTextError, .unsupportedSampleRate(11_025))
        XCTAssertEqual(rate.client.sampleRate, 11_025, "The effective rate is the requested one")
        for supported in XAISpeechToText.supportedSampleRates {
            let fixture = XAISpeechToTextLiveFixture(sampleRate: supported)
            fixture.start()
            XCTAssertEqual(fixture.factory.requests.count, 1)
            XCTAssertEqual(fixture.factory.requests[0].url?.query?.contains("sample_rate=\(supported)"), true)
            fixture.client.cancel()
        }
    }

    func testReadyAndSendDeadlinesFailWithinTheirScheduledBudgets() {
        let connecting = XAISpeechToTextLiveFixture()
        connecting.start()
        connecting.socket.open()
        connecting.clock.fire(XAISpeechToTextLiveClient.readyDeadline)
        XCTAssertEqual(connecting.events.errors.first as? XAISpeechToTextError, .sessionNotReady)
        XCTAssertEqual(connecting.socket.cancels, 1)

        let stalled = XAISpeechToTextLiveFixture()
        stalled.start()
        stalled.becomeReady()
        stalled.client.sendAudio(XAISpeechToTextLiveFixture.frame(1))
        stalled.clock.fire(XAISpeechToTextLiveClient.sendDeadline)
        XCTAssertEqual(stalled.events.errors.count, 1)
        guard case StreamingClientError.transportStalled? = stalled.events.errors.first else {
            return XCTFail("Expected a visible transport stall")
        }
        XCTAssertEqual(stalled.socket.cancels, 1)
        stalled.socket.completeSend()
        XCTAssertEqual(stalled.events.errors.count, 1, "A late completion cannot fail the run twice")
    }

    func testOldSocketCallbacksAndDeadlinesCannotMutateTheReplacementRun() {
        let fixture = XAISpeechToTextLiveFixture()
        fixture.start()
        let old = fixture.socket
        fixture.becomeReady()
        fixture.client.sendAudio(XAISpeechToTextLiveFixture.frame(1))
        let oldDeadlines = fixture.clock.drain()
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        XCTAssertEqual(old.cancels, 1)
        old.open()
        old.transcriptPartial("Stale.", isFinal: true, start: 0)
        old.transcriptDone("Stale done.")
        old.xaiError("stale failure")
        old.completeSend(URLError(.networkConnectionLost))
        oldDeadlines.forEach { $0() }
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertTrue(fixture.events.texts.isEmpty)
        XCTAssertFalse(fixture.client.isSessionReady)
        replacement.open()
        replacement.transcriptCreated()
        replacement.transcriptPartial("Current.", isFinal: true, start: 0)
        fixture.client.sendAudio(XAISpeechToTextLiveFixture.frame(2))
        XCTAssertEqual(replacement.binary, [XAISpeechToTextLiveFixture.frame(2)])
        XCTAssertEqual(fixture.events.texts, ["Current."])
        XCTAssertTrue(fixture.client.isSessionReady)
        XCTAssertEqual(fixture.factory.sockets.count, 2, "A stopped run never reconnects")
        fixture.client.cancel()
    }

    func testStopLatchesTheRunSoLateFramesAndAudioAreIgnored() async {
        let fixture = XAISpeechToTextLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.transcriptPartial("Kept.", isFinal: true, start: 0)
        fixture.client.stop()
        XCTAssertEqual(fixture.socket.cancels, 1)
        fixture.socket.transcriptPartial("Late.", isFinal: true, start: 1)
        fixture.socket.fail()
        fixture.client.sendAudio(XAISpeechToTextLiveFixture.frame(1))
        XCTAssertEqual(fixture.events.texts, ["Kept."])
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertTrue(fixture.socket.binary.isEmpty)
        XCTAssertTrue(fixture.client.preroll.isEmpty, "A stopped session holds nothing for a later drain")
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Kept.", "Text received before the stop stays available")
    }

    func testOfflinePrerollContractHoldsAudioOnlyBeforeAStart() {
        let fixture = XAISpeechToTextLiveFixture()
        let first = XAISpeechToTextLiveFixture.frame(1)
        fixture.client.sendAudio(first)
        XCTAssertEqual(fixture.client.preroll.drain(), [first])
        fixture.client.stop()
        fixture.client.sendAudio(XAISpeechToTextLiveFixture.frame(2))
        XCTAssertTrue(fixture.client.preroll.isEmpty)
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
    }

    func testParserReadsWholeSecondStartsTheSameWayOnEveryFoundation() throws {
        func event(_ json: String) throws -> XAISpeechToTextEvent {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return try XCTUnwrap(XAISpeechToTextEvent(object: object))
        }
        XCTAssertEqual(
            try event(#"{"type":"transcript.partial","text":"Two","is_final":true,"speech_final":true,"start":2}"#),
            .partial(text: "Two", isFinal: true, speechFinal: true, eventID: "0:2.0")
        )
        XCTAssertEqual(
            try event(#"{"type":"transcript.partial","text":"Half","is_final":true,"start":1.5,"channel_index":1}"#),
            .partial(text: "Half", isFinal: true, speechFinal: false, eventID: "1:1.5")
        )
        XCTAssertEqual(
            try event(#"{"type":"transcript.partial","text":"Hel","is_final":false}"#),
            .partial(text: "Hel", isFinal: false, speechFinal: false, eventID: nil)
        )
        let fixture = XAISpeechToTextLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.emit(#"{"type":"keepalive"}"#)
        fixture.socket.emit("not json")
        fixture.socket.transcriptPartial("Alive.", isFinal: true, start: 0)
        XCTAssertEqual(fixture.events.texts, ["Alive."], "Unknown frames never end a live recording")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
    }

    /// A channel index the frame cannot use must never trap the recording.
    /// Apple's JSONSerialization answers `1e100` as a Double whose rounded
    /// value equals itself, so only an exact conversion is safe.
    func testParserReadsUnusableChannelIndexesWithoutTrappingAndFallsBackToChannelZero() throws {
        func identity(channel: String) throws -> String? {
            let json = #"{"type":"transcript.partial","text":"x","is_final":true,"start":2,"channel_index":"#
                + channel + "}"
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            guard case .partial(_, _, _, let eventID) = try XCTUnwrap(XAISpeechToTextEvent(object: object)) else {
                XCTFail("Expected a partial frame for channel \(channel)")
                return nil
            }
            return eventID
        }
        XCTAssertEqual(try identity(channel: "1"), "1:2.0")
        XCTAssertEqual(try identity(channel: "1.0"), "1:2.0", "An integral double is an ordinary index")
        XCTAssertEqual(try identity(channel: "1e18"), "1000000000000000000:2.0")
        XCTAssertEqual(try identity(channel: "9007199254740993"), "9007199254740993:2.0")
        XCTAssertEqual(try identity(channel: "1e100"), "0:2.0", "Out of range is unusable, not fatal")
        XCTAssertEqual(try identity(channel: "-1e308"), "0:2.0")
        XCTAssertEqual(try identity(channel: "1.5"), "0:2.0", "A fractional index is unusable")
        XCTAssertEqual(try identity(channel: "\"1\""), "0:2.0", "A string is not an index")
    }
}
