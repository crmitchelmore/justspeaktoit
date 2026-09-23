import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Drives the real shared Speechmatics client through the injected transport.
/// Every request, message and ordering assertion is complete, and finish/
/// readiness waits use the injected scheduler instead of long sleeps.
final class SpeechmaticsPortableLifecycleTests: XCTestCase {

    // MARK: - Endpoint, header and StartRecognition

    func testCanonicalEndpointHeaderAndStartRecognitionPayload() throws {
        let fixture = SpeechmaticsLiveFixture(language: "en_GB")
        fixture.start()
        let request = fixture.factory.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "wss://eu.rt.speechmatics.com/v2/")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")

        let socket = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        XCTAssertTrue(socket.controls.isEmpty, "Nothing is sent before the handshake completes")
        socket.open()
        XCTAssertEqual(socket.messageNames, ["StartRecognition"])

        let payload = try XCTUnwrap(socket.objects.first)
        let audio = try XCTUnwrap(payload["audio_format"] as? [String: Any])
        XCTAssertEqual(audio["type"] as? String, "raw")
        XCTAssertEqual(audio["encoding"] as? String, "pcm_s16le")
        XCTAssertEqual(audio["sample_rate"] as? Int, 16_000)
        let config = try XCTUnwrap(payload["transcription_config"] as? [String: Any])
        XCTAssertEqual(config["language"] as? String, "en")
        XCTAssertEqual(config["model"] as? String, "enhanced")
        XCTAssertNil(config["operating_point"])
        XCTAssertEqual(config["max_delay"] as? Double, 0.7)
        XCTAssertEqual(config["enable_partials"] as? Bool, true)

        XCTAssertTrue(socket.binary.isEmpty, "The socket opening alone is not recognition readiness")
        socket.completeSend()
        XCTAssertTrue(socket.binary.isEmpty, "Even a completed StartRecognition is not readiness")
        socket.recognitionStarted()
        XCTAssertEqual(socket.binary.map(\.count), [3_200], "RecognitionStarted releases the held audio")
        fixture.client.cancel()
    }

    func testMissingKeyDoesNotOpenATransport() {
        let fixture = SpeechmaticsLiveFixture(key: " \n")
        fixture.start()
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
        XCTAssertEqual(fixture.events.errors.count, 1)
        guard case StreamingClientError.missingAPIKey? = fixture.events.errors.first as? StreamingClientError else {
            return XCTFail("Expected a missing-key error, got \(String(describing: fixture.events.errors.first))")
        }
    }

    // MARK: - PCM handling

    func testAudioBeforeOpenAndBeforeRecognitionStartedIsHeldThenDrainedInOrder() {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        let socket = fixture.socket
        let first = Data(repeating: 1, count: 3_200)
        let second = Data(repeating: 2, count: 3_200)
        fixture.client.sendAudio(first)
        socket.open()
        fixture.client.sendAudio(second)
        XCTAssertTrue(socket.binary.isEmpty, "No audio before RecognitionStarted, even after the handshake")
        socket.completeSend()
        XCTAssertTrue(socket.binary.isEmpty, "A completed StartRecognition still is not readiness")
        socket.recognitionStarted()
        XCTAssertEqual(socket.binary, [first], "Exactly one send is in flight")
        socket.completeSend()
        XCTAssertEqual(socket.binary, [first, second], "Held capture drains in exact capture order")
        fixture.client.cancel()
    }

    func testSubminimumChunksCoalesceIntoLegalFramesInCaptureOrder() {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 2_000))
        XCTAssertTrue(socket.binary.isEmpty, "Below the 3,200-byte minimum, capture is held")
        fixture.client.sendAudio(Data(repeating: 2, count: 2_000))
        XCTAssertEqual(socket.binary.count, 1, "Coalesced into one legal frame once the minimum is reached")
        XCTAssertEqual(socket.binary[0].count, 4_000)
        XCTAssertEqual(socket.binary[0].prefix(2_000), Data(repeating: 1, count: 2_000))
        XCTAssertEqual(socket.binary[0].suffix(2_000), Data(repeating: 2, count: 2_000))
        fixture.client.sendAudio(Data(repeating: 3, count: 4_000))
        XCTAssertEqual(socket.binary.count, 1, "Only one send is in flight")
        socket.completeSend()
        XCTAssertEqual(socket.binary.count, 2, "The next frame follows once the first completes")
        XCTAssertEqual(socket.binary[1], Data(repeating: 3, count: 4_000))
        fixture.client.cancel()
    }

    func testFinishPadsTheShortFinalTailWithoutDuplicationOrLoss() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(Data(repeating: 7, count: 3_200))
        fixture.client.sendAudio(Data(repeating: 9, count: 1_000))
        XCTAssertEqual(socket.binary.count, 1)
        let finish = Task { await fixture.client.finishAndWait() }
        socket.completeSend()
        await fixture.settle { socket.binary.count == 2 }
        XCTAssertEqual(socket.binary[1].count, 3_200, "The short tail is padded to the minimum frame size")
        XCTAssertEqual(socket.binary[1].prefix(1_000), Data(repeating: 9, count: 1_000))
        XCTAssertTrue(socket.binary[1].dropFirst(1_000).allSatisfy { $0 == 0 })
        socket.completeSend()
        await fixture.settle { socket.messageNames.last == "EndOfStream" }
        socket.completeSend()
        socket.endOfTranscript()
        _ = await finish.value
        XCTAssertEqual(socket.binary.count, 2, "No duplicate tail is sent")
    }

    func testEndOfStreamReportsFrameCountFlooredByAcknowledgements() async throws {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        socket.completeSend()
        fixture.client.sendAudio(Data(repeating: 2, count: 3_200))
        socket.completeSend()
        socket.audioAdded(5)
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.messageNames.last == "EndOfStream" }
        XCTAssertEqual(try XCTUnwrap(socket.lastControlObject)["last_seq_no"] as? Int, 5,
                       "An acknowledged seq_no ahead of the frame count is the floor")
        socket.completeSend()
        socket.endOfTranscript()
        _ = await finish.value
    }

    func testEndOfStreamUsesTransmittedFrameCountWhenAcknowledgementsLag() async throws {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        socket.completeSend()
        fixture.client.sendAudio(Data(repeating: 2, count: 3_200))
        socket.completeSend()
        socket.audioAdded(1)
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.messageNames.last == "EndOfStream" }
        XCTAssertEqual(try XCTUnwrap(socket.lastControlObject)["last_seq_no"] as? Int, 2,
                       "The transmitted frame count is reported when acknowledgements lag")
        socket.completeSend()
        socket.endOfTranscript()
        _ = await finish.value
    }

    // MARK: - Finish ordering

    func testFinishBeforeSocketOpenSendsLeadingCaptureAfterReadiness() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        let socket = fixture.socket
        let opening = Data(repeating: 42, count: 3_200)
        fixture.client.sendAudio(opening)
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(SpeechmaticsLiveClient.finishReadyBudget)
        XCTAssertTrue(socket.controls.isEmpty, "Nothing is sent before the handshake")
        socket.open()
        socket.completeSend()
        socket.recognitionStarted()
        XCTAssertEqual(socket.binary, [opening], "The accepted leading capture survives the finish")
        socket.completeSend()
        await fixture.settle { socket.messageNames.last == "EndOfStream" }
        socket.completeSend()
        socket.endOfTranscript()
        _ = await finish.value
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.factory.sockets.count, 1)
    }

    func testEndOfStreamFollowsEveryAudioSendAndNeverOvertakesIt() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        fixture.client.sendAudio(Data(repeating: 2, count: 3_200))
        fixture.client.sendAudio(Data(repeating: 3, count: 3_200))
        XCTAssertEqual(socket.binary.count, 1)
        let finish = Task { await fixture.client.finishAndWait() }
        socket.completeSend()
        socket.completeSend()
        XCTAssertFalse(socket.messageNames.contains("EndOfStream"), "EndOfStream cannot overtake unfinished audio")
        XCTAssertEqual(socket.binary.count, 3)
        socket.completeSend()
        await fixture.settle { socket.messageNames.last == "EndOfStream" }
        socket.completeSend()
        socket.endOfTranscript()
        _ = await finish.value
    }

    func testRepeatedAndTrailingFinalSegmentsSurviveAndAreReturnedOnce() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.addFinal("Yes.", start: 0, end: 1)
        socket.addFinal("Yes.", start: 1, end: 2)
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.messageNames.last == "EndOfStream" }
        socket.completeSend()
        socket.addFinal("Goodbye.", start: 2, end: 3)
        socket.endOfTranscript()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Yes. Yes. Goodbye.")
        XCTAssertEqual(fixture.events.texts, ["Yes.", "Yes.", "Goodbye."])
        XCTAssertEqual(fixture.events.finals, [true, true, true])
    }

    func testTwoFinishCallersBothResolveWithTheWholeTranscript() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.addFinal("Done.")
        let first = Task { await fixture.client.finishAndWait() }
        let second = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.messageNames.last == "EndOfStream" }
        socket.completeSend()
        socket.endOfTranscript()
        let values = await [first.value, second.value]
        XCTAssertEqual(values[0], "Done.")
        XCTAssertEqual(values[1], "Done.")
    }

    func testEndOfTranscriptAndFinishBudgetTimerCannotDoubleResume() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.addFinal("Committed.")
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.messageNames.last == "EndOfStream" }
        socket.completeSend()
        socket.endOfTranscript()
        fixture.clock.fire(SpeechmaticsLiveClient.finishBudget)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Committed.")
    }
}
