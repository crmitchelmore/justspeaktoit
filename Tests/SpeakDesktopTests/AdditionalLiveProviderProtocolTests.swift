import Foundation
@testable import SpeakCore
import XCTest

final class AdditionalLiveProviderProtocolTests: XCTestCase {
    func testExistingMetaOfflineHandshakeSeamKeepsItsConfiguredState() {
        let client = MetaMuseLiveClient(apiKey: "synthetic")
        client.beginSession(onTranscript: { _, _ in }, onError: { XCTFail("\($0)") })
        client.ingest(#"{"sessionId":"synthetic"}"#)
        client.ingest(#"{"type":"unknown-future-event"}"#)
        XCTAssertTrue(client.isSessionConfigured)
        client.stop()
    }

    func testModulateHeaderIsSentOncePerRunAndDoneIsRequiredAfterEmptyTextEnd() async {
        let fixture = AdditionalLiveProviderFixture(.modulate)
        fixture.start()
        fixture.becomeReady()
        let frame = fixture.frame(9)
        fixture.client.sendAudio(frame)
        let first = fixture.socket.binary[0]
        XCTAssertEqual(first.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(first.subdata(in: 8..<12), Data("WAVE".utf8))
        XCTAssertEqual(first.count, frame.count + 44)
        XCTAssertEqual(first.dropFirst(44), frame)
        fixture.socket.completeSend()
        fixture.client.sendAudio(frame)
        XCTAssertEqual(fixture.socket.binary[1], frame)
        fixture.socket.completeSend()
        fixture.client.cancel()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(frame)
        XCTAssertEqual(fixture.socket.binary[0], first, "Restart must send its own WAV header")
        fixture.client.cancel()
    }

    func testMetaRetriesOnlyOnePreHandshakeFailureAndKeepsPendingCapture() {
        let fixture = AdditionalLiveProviderFixture(.meta)
        fixture.start()
        fixture.client.sendAudio(fixture.frame(7))
        let original = fixture.socket
        original.open()
        original.fail()
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        original.completeSend()
        original.emit(#"{"sessionId":"retired"}"#)
        fixture.becomeReady()
        XCTAssertEqual(fixture.socket.binary, [fixture.frame(7)])
        fixture.socket.fail()
        XCTAssertEqual(fixture.factory.sockets.count, 2, "No retry after readiness")
        XCTAssertEqual(fixture.events.errors.count, 1)
    }

    func testGeminiGoAwayReconnectRetainsTranscriptAndIgnoresRetiredSocket() async {
        let fixture = AdditionalLiveProviderFixture(.gemini)
        fixture.start()
        fixture.becomeReady()
        fixture.socket.emit(AdditionalLiveProvider.gemini.final("Before."))
        let old = fixture.socket
        old.emit(#"{"goAway":{"timeLeft":"5s"}}"#)
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        fixture.becomeReady()
        old.emit(AdditionalLiveProvider.gemini.final("Retired."))
        fixture.socket.emit(AdditionalLiveProvider.gemini.final("New."))
        fixture.client.cancel()
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Before. New.")
        XCTAssertEqual(fixture.events.texts, ["Before.", "New."])
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testGrokManualTurnsNeverRequestAssistantGenerationAndIgnoreAssistantFrames() throws {
        let fixture = AdditionalLiveProviderFixture(.grok)
        fixture.start()
        fixture.becomeReady()
        let setup = try XCTUnwrap(fixture.socket.controls.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(setup.utf8)) as? [String: Any])
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        XCTAssertTrue(session["turn_detection"] is NSNull)
        fixture.socket.emit(#"{"type":"response.audio_transcript.done","transcript":"Assistant."}"#)
        fixture.socket.emit(#"{"type":"response.output_audio.delta","delta":"AA=="}"#)
        XCTAssertTrue(fixture.events.texts.isEmpty)
        XCTAssertFalse(fixture.socket.controls.contains { $0.contains("response.create") })
        fixture.client.cancel()
    }
}
