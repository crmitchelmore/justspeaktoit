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
        XCTAssertEqual(query["commit_strategy"], "manual")
        XCTAssertEqual(query["language_code"], "en", "A locale is reduced to an ISO-639 language code")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "synthetic")

        let socket = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        socket.open()
        XCTAssertTrue(socket.controls.isEmpty, "Nothing is sent before session_started")
        XCTAssertFalse(fixture.client.isConnected)
        socket.emit(ElevenLabsFixture.started())
        XCTAssertTrue(fixture.client.isConnected)
        XCTAssertEqual(ElevenLabsFixture.audioChunks(socket), [Data(repeating: 1, count: 3_200)])
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
        socket.emit(ElevenLabsFixture.started())
        XCTAssertEqual(ElevenLabsFixture.audioChunks(socket), [first], "Exactly one send is in flight")
        socket.completeSend()
        XCTAssertEqual(ElevenLabsFixture.audioChunks(socket), [first, second])
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
        socket.emit(ElevenLabsFixture.started())
        fixture.client.sendAudio(Data(repeating: 1, count: 160_000))
        fixture.client.sendAudio(Data([1, 2]))
        fixture.client.sendAudio(Data([3, 4]))
        XCTAssertEqual(ElevenLabsFixture.audioChunks(socket).count, 1)
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
        socket.emit(ElevenLabsFixture.started())
        XCTAssertTrue(socket.controls.isEmpty, "A failed run never sends after the handshake")
    }

    // MARK: - Duplicate / interim final replacement

    func testPartialsReplaceCommittedSegmentsAppendAndIdenticalFinalsAreBothKept() async {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(ElevenLabsFixture.partial("hel"))
        socket.emit(ElevenLabsFixture.partial("hello"))
        fixture.commit("Hello.")
        fixture.commit("Hello.")
        socket.emit(ElevenLabsFixture.partial("yes"))
        fixture.commit("Yes.")
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
        fixture.commit("Hello.")
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        let finish = Task { await fixture.client.finishAndWait() }
        XCTAssertEqual(ElevenLabsFixture.audioChunks(socket).count, 5)
        socket.completeSend()
        await fixture.settle { ElevenLabsFixture.commitCount(socket) == 2 }
        XCTAssertEqual(ElevenLabsFixture.audioChunks(socket).count, 5, "Only the admitted audio, then the commit")
        socket.completeSend()
        socket.emit(ElevenLabsFixture.committed("World."))
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Hello. World.")
        XCTAssertEqual(fixture.events.texts, ["Hello."], "The trailing final is returned once, not re-delivered")
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testFinishWithNoTrailingFinalFailsAtTheBudgetWithBestAvailableText() async {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.commit("Only segment.")
        fixture.client.sendAudio(Data(repeating: 0, count: 3_200))
        socket.completeSend()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { ElevenLabsFixture.commitCount(socket) == 2 }
        socket.completeSend()
        fixture.clock.fire(ElevenLabsLiveClient.finishBudget)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Only segment.")
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertEqual(fixture.events.errors.first as? ElevenLabsStreamingError, .missingCompletion)
    }

    func testEmptyFinishReturnsNilWithoutSendingACommit() async {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        let transcript = await fixture.client.finishAndWait()
        XCTAssertNil(transcript)
        XCTAssertEqual(ElevenLabsFixture.commitCount(fixture.socket), 0)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.socket.cancels, 1)
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
        socket.emit(ElevenLabsFixture.started())
        XCTAssertEqual(ElevenLabsFixture.audioChunks(socket), [opening])
        socket.completeSend()
        await fixture.settle { ElevenLabsFixture.commitCount(socket) == 1 }
        socket.completeSend()
        socket.emit(ElevenLabsFixture.committed("Opening words."))
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

}
