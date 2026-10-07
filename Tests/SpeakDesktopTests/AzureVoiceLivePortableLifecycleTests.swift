import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// The shared Azure Voice Live client's connection, readiness and live
/// delivery, driven through a fake transport and clock. Synthetic data only.
final class AzureVoiceLivePortableLifecycleTests: XCTestCase {
    func testRequestUsesTheResourceOriginAndKeyHeaderAndConfiguresTranscriptionOnly() throws {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        let request = try XCTUnwrap(fixture.factory.requests.first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "synthetic.services.ai.azure.com")
        XCTAssertEqual(url.path, "/voice-live/realtime")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.query,
                       "api-version=2026-04-10&model=gpt-4.1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "synthetic-key")
        XCTAssertFalse(url.absoluteString.contains("synthetic-key"), "The key never enters the URL")
        XCTAssertTrue(fixture.socket.controls.isEmpty, "Nothing is sent before the transport's handshake")

        fixture.socket.open()
        let update = try XCTUnwrap(fixture.socket.sessionUpdate)
        let session = try XCTUnwrap(update["session"] as? [String: Any])
        XCTAssertEqual(update["event_id"] as? String, fixture.client.currentEventIDs.session)
        XCTAssertEqual(session["modalities"] as? [String], ["text"])
        XCTAssertEqual(session["input_audio_format"] as? String, "pcm16")
        XCTAssertEqual(session["input_audio_sampling_rate"] as? Int, 24_000)
        XCTAssertEqual((session["input_audio_transcription"] as? [String: Any])?["model"] as? String, "azure-speech")
        let turns = try XCTUnwrap(session["turn_detection"] as? [String: Any])
        XCTAssertEqual(turns["type"] as? String, "azure_semantic_vad")
        XCTAssertEqual(turns["create_response"] as? Bool, false, "Voice Live never generates a response")
        XCTAssertFalse(fixture.socket.controls.joined().contains("response.create"))
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testAudioWaitsForTheConfigurationAcknowledgementAndLeavesInCaptureOrderOneAtATime() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        let socket = fixture.socket
        let frames = (0..<3).map { AzureVoiceLiveFixture.frame($0) }
        fixture.client.sendAudio(frames[0])
        socket.open()
        fixture.client.sendAudio(frames[1])
        socket.completeSend()
        socket.created()
        XCTAssertFalse(fixture.client.isSessionReady, "session.created is not readiness")
        XCTAssertTrue(socket.audio.isEmpty, "Audio waits for Azure to acknowledge the configuration")
        socket.acknowledge(sessionType: nil)
        XCTAssertTrue(fixture.client.isSessionReady)
        XCTAssertTrue(fixture.client.readiness.isReady)
        fixture.client.sendAudio(frames[2])
        XCTAssertEqual(socket.audio, [frames[0]], "Exactly one send is in flight")
        socket.completeSend()
        socket.completeSend()
        XCTAssertEqual(socket.audio, frames, "Held and live audio leave in capture order")
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testInvalidConfigurationIsReportedBeforeAnyConnectionIsCreated() {
        let credentials = "Enter your Azure key and region as key:region."
        let endpoint = "Add the HTTPS resource endpoint from Azure in API Keys settings."
        let cases = [
            InvalidConfiguration(credentials: "", message: credentials),
            InvalidConfiguration(credentials: "key:bad.region/path", message: credentials),
            InvalidConfiguration(endpoint: "", message: endpoint),
            InvalidConfiguration(endpoint: "https://synthetic.services.ai.azure.com.evil.example", message: endpoint),
            InvalidConfiguration(
                model: "mai-transcribe-2", message: AzureSpeechError.unsupportedModel.errorDescription
            ),
            InvalidConfiguration(
                rate: 44_100, message: AzureVoiceLiveError.unsupportedSampleRate(44_100).errorDescription
            )
        ]
        for invalid in cases {
            let fixture = AzureVoiceLiveFixture(
                model: invalid.model, credentials: invalid.credentials, endpoint: invalid.endpoint,
                sampleRate: invalid.rate
            )
            fixture.start()
            XCTAssertTrue(fixture.factory.sockets.isEmpty, "\(invalid) must not open a connection")
            XCTAssertEqual(fixture.events.errors.map(\.localizedDescription), [invalid.message ?? ""], "\(invalid)")
        }
    }

    func testTheReadinessDeadlineFailsASessionAzureNeverAcknowledges() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.socket.open()
        fixture.socket.completeSend()
        fixture.clock.fire(AzureVoiceLiveClient.readyDeadline)
        XCTAssertEqual(fixture.events.errors.first as? AzureVoiceLiveError, .sessionNotReady)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testLiveDeliveriesKeepConfirmedFinalsApartFromDrafts() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.committed("item_a")
        socket.delta("Hel", item: "item_a")
        socket.delta("lo", item: "item_a")
        socket.committed("item_b")
        socket.delta("Sec", item: "item_b")
        socket.completed("Hello.", item: "item_a")
        socket.completed("Hello.", item: "item_a")
        socket.completed("Hello.", item: "item_b")
        XCTAssertEqual(fixture.events.texts, ["Hel", "Hello", "Hello Sec", "Hello.", "Hello. Sec", "Hello. Hello."])
        XCTAssertEqual(fixture.events.finals, [false, false, false, true, false, true],
                       "A final carries confirmed text only; drafts follow as the interim display")
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testAFailedTurnKeepsTheSessionAndOnlyAnAllFailedRecordingIsAnError() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.committed("item_a")
        socket.transcriptionFailed(item: "item_a", message: "Synthetic unintelligible turn")
        socket.committed("item_b")
        socket.completed("Still here.", item: "item_b")
        XCTAssertEqual(fixture.events.texts, ["Still here."])
        XCTAssertTrue(fixture.events.errors.isEmpty, "One failed turn is not a session failure")
        fixture.client.cancel()

        let silent = AzureVoiceLiveFixture()
        silent.client.beginSession(onTranscript: { _, _ in }, onError: { [events = silent.events] in events.fail($0) })
        silent.client.ingest(#"{"type":"input_audio_buffer.committed","item_id":"item_a"}"#)
        silent.client.ingest(#"{"type":"conversation.item.input_audio_transcription.failed","item_id":"item_a"}"#)
        let nothing = await silent.client.finishAndWait()
        XCTAssertNil(nothing)
        XCTAssertEqual(silent.events.errors.map(\.localizedDescription),
                       [AzureSpeechError.transcriptionFailed.localizedDescription])
    }

    func testEachModelReceivesTheLanguageFormItDocumentsAndAutomaticSendsNone() throws {
        let expectations = [
            LanguageExpectation(model: "azure-speech", language: "en_GB", sent: "en-GB"),
            LanguageExpectation(model: "mai-transcribe", language: "en_GB", sent: "en"),
            LanguageExpectation(model: "azure-speech", language: "ja_JP", sent: "ja-JP"),
            LanguageExpectation(model: "mai-transcribe", language: "ja_JP", sent: "ja"),
            LanguageExpectation(model: "azure-speech", language: "automatic", sent: nil),
            LanguageExpectation(model: "mai-transcribe", language: "Automatic", sent: nil),
            LanguageExpectation(model: "azure-speech", language: " ", sent: nil),
            LanguageExpectation(model: "mai-transcribe", language: nil, sent: nil)
        ]
        for expected in expectations {
            let fixture = AzureVoiceLiveFixture(model: expected.model, language: expected.language)
            fixture.start()
            fixture.socket.open()
            let session = try XCTUnwrap(fixture.socket.sessionUpdate?["session"] as? [String: Any])
            let transcription = try XCTUnwrap(session["input_audio_transcription"] as? [String: Any])
            XCTAssertEqual(transcription["model"] as? String, expected.model)
            XCTAssertEqual(transcription["language"] as? String, expected.sent, "\(expected)")
            fixture.client.cancel()
        }
    }

    func testAudioBeforeStartIsHeldAndReplayedFirst() {
        let fixture = AzureVoiceLiveFixture()
        let early = AzureVoiceLiveFixture.frame(9)
        fixture.client.sendAudio(early)
        XCTAssertEqual(fixture.client.preroll.snapshot.byteCount, early.count)
        fixture.start()
        fixture.becomeReady()
        XCTAssertEqual(fixture.socket.audio, [early])
        XCTAssertEqual(fixture.client.preroll.snapshot.byteCount, 0)
    }

    func testAnOddLengthFrameAndAStalledTransportFailVisiblyInsteadOfDroppingAudio() {
        let odd = AzureVoiceLiveFixture()
        odd.start()
        odd.becomeReady()
        odd.client.sendAudio(Data(repeating: 1, count: 4_801))
        XCTAssertEqual(odd.events.errors.first as? AzureVoiceLiveError, .invalidPCM)
        XCTAssertEqual(odd.socket.cancels, 1)

        let stalled = AzureVoiceLiveFixture()
        stalled.start()
        stalled.becomeReady()
        for index in 0..<50 { stalled.client.sendAudio(AzureVoiceLiveFixture.frame(index)) }
        XCTAssertTrue(stalled.events.errors.isEmpty, "Five seconds of audio fits the bound")
        stalled.client.sendAudio(AzureVoiceLiveFixture.frame(50))
        XCTAssertEqual(stalled.events.errors.count, 1)
        XCTAssertTrue(stalled.events.errors.first is StreamingClientError)
        XCTAssertEqual(stalled.socket.cancels, 1)
        stalled.client.sendAudio(AzureVoiceLiveFixture.frame(51))
        XCTAssertEqual(stalled.events.errors.count, 1, "A failure is reported once")
    }

    func testASendThatNeverCompletesIsReportedAtTheSendDeadline() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        fixture.clock.fire(AzureVoiceLiveClient.sendDeadline)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertTrue(fixture.events.errors.first is StreamingClientError)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }
}

/// One configuration the client must refuse before connecting, and the
/// message it reports; unspecified fields are valid.
private struct InvalidConfiguration: CustomStringConvertible {
    var credentials = AzureVoiceLiveFixture.credentials
    var endpoint = AzureVoiceLiveFixture.endpoint
    var model = "azure-speech"
    var rate = 24_000
    var message: String?

    var description: String { "\(model) at \(rate) Hz via \(endpoint.isEmpty ? "no endpoint" : endpoint)" }
}

private struct LanguageExpectation {
    let model: String
    let language: String?
    let sent: String?
}
