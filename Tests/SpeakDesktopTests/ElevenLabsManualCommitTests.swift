import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

final class ElevenLabsManualCommitTests: XCTestCase {
    func testCrossingChunkSplitsBeforeTwentySecondsAndWaitsForPriorFinal() async {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        let prefix = Data(repeating: 1, count: 152_000) // 4.75 s each, 19 s total.
        for _ in 0..<4 {
            fixture.client.sendAudio(prefix)
            socket.completeSend()
        }
        let crossing = Data((0..<96_000).map { UInt8($0 % 251) }) // Three seconds.
        fixture.client.sendAudio(crossing)
        XCTAssertEqual(audio(socket).last, Data(crossing.prefix(32_000)))
        socket.completeSend()
        XCTAssertEqual(commits(socket), 1)
        socket.completeSend()
        XCTAssertEqual(audio(socket).reduce(0) { $0 + $1.count }, 640_000)
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { fixture.clock.pending(ElevenLabsLiveClient.finishDrainBudget) > 1 }
        socket.emit(final("First."))
        XCTAssertEqual(audio(socket).last, Data(crossing.dropFirst(32_000)))
        XCTAssertEqual(socket.cancels, 0, "The prior segment's final cannot finish unsent trailing audio")
        socket.emit(timestamp("First."))
        socket.completeSend()
        XCTAssertEqual(commits(socket), 2)
        socket.completeSend()
        socket.emit(final("Second."))
        let text = await finish.value
        XCTAssertEqual(text, "First. Second.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(audio(socket).reduce(Data(), +), prefix + prefix + prefix + prefix + crossing)
    }

    func testStopAtPeriodicBoundaryDoesNotSendAnEmptySecondCommit() async {
        let fixture = readyFixture()
        fillSegment(fixture)
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { fixture.clock.pending(ElevenLabsLiveClient.finishDrainBudget) > 1 }
        fixture.socket.completeSend()
        fixture.socket.emit(final("Boundary."))
        let text = await finish.value
        XCTAssertEqual(text, "Boundary.")
        XCTAssertEqual(commits(fixture.socket), 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testFinalBeforeCommitSendCompletionDoesNotFinishAndSendFailureRemainsVisible() async {
        let fixture = readyFixture()
        fixture.client.sendAudio(Data(repeating: 1, count: 320)) // Ten milliseconds.
        fixture.socket.completeSend()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { self.commits(fixture.socket) == 1 }
        fixture.socket.emit(final("Short."))
        XCTAssertEqual(fixture.socket.cancels, 0, "Receiving text does not prove the pending send succeeded")
        fixture.socket.completeSend(URLError(.networkConnectionLost))
        let text = await finish.value
        XCTAssertEqual(text, "Short.")
        XCTAssertEqual(fixture.events.errors.count, 1, "Error must precede the finish return")
    }

    func testInlineFinalBeforeCommitSendCompletionCanSucceed() async {
        let fixture = readyFixture()
        let socket = fixture.socket
        socket.onSend = { message in
            if case .text(let text) = message, text.contains("\"commit\":true") {
                socket.emit(#"{"message_type":"committed_transcript","text":"Inline."}"#)
            }
        }
        fixture.client.sendAudio(Data(repeating: 1, count: 320))
        socket.completeSend()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { self.commits(socket) == 1 }
        XCTAssertEqual(socket.cancels, 0)
        socket.completeSend()
        let text = await finish.value
        XCTAssertEqual(text, "Inline.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testShortSilentAudioNeedsARealFinalOrAnExplicitTimeout() async {
        for receivesFinal in [false, true] {
            let fixture = readyFixture()
            fixture.client.sendAudio(Data(repeating: 0, count: 320))
            fixture.socket.completeSend()
            let finish = Task { await fixture.client.finishAndWait() }
            await fixture.settle { self.commits(fixture.socket) == 1 }
            fixture.socket.completeSend()
            if receivesFinal {
                fixture.socket.emit(final(""))
            } else {
                fixture.clock.fire(ElevenLabsLiveClient.finishBudget)
            }
            let text = await finish.value
            XCTAssertNil(text)
            XCTAssertEqual(fixture.events.errors.count, receivesFinal ? 0 : 1)
            if !receivesFinal {
                XCTAssertEqual(fixture.events.errors.first as? ElevenLabsStreamingError, .missingCompletion)
            }
        }
    }

    func testPeriodicCommitTimeoutFailsAndDoesNotSendQueuedNextSegment() {
        let fixture = readyFixture()
        fillSegment(fixture)
        fixture.socket.completeSend()
        fixture.client.sendAudio(Data(repeating: 1, count: 3200))
        fixture.clock.fire(ElevenLabsLiveClient.finishBudget)
        XCTAssertEqual(audio(fixture.socket).reduce(0) { $0 + $1.count }, 640_000)
        XCTAssertEqual(fixture.events.errors.first as? ElevenLabsStreamingError, .missingCompletion)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testWaitingForACommitStillBoundsAdmittedBacklog() {
        let fixture = readyFixture()
        fillSegment(fixture)
        fixture.socket.completeSend()
        fixture.client.sendAudio(Data(repeating: 1, count: 160_000))
        fixture.client.sendAudio(Data([1, 0]))
        XCTAssertEqual(fixture.events.errors.count, 1)
        guard case StreamingClientError.transportStalled? = fixture.events.errors.first else {
            return XCTFail("A missing final must not cause an unbounded recording queue")
        }
        XCTAssertEqual(audio(fixture.socket).count, 4)
    }

    func testWholeFinishDeadlineBoundsSlowDrainAndPreservesConfirmedText() async {
        let fixture = readyFixture()
        fixture.commit("Saved.")
        fixture.client.sendAudio(Data(repeating: 1, count: 3200))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { fixture.clock.pending(ElevenLabsLiveClient.finishDrainBudget) > 1 }
        fixture.clock.fire(ElevenLabsLiveClient.finishDrainBudget)
        let text = await finish.value
        XCTAssertEqual(text, "Saved.")
        XCTAssertEqual(fixture.events.errors.first as? ElevenLabsStreamingError, .missingCompletion)
    }

    func testPreStartAudioIsReplayedInOrderThroughTheSameAdmissionPath() {
        let fixture = ElevenLabsFixture()
        let first = Data([1, 0, 2, 0])
        let second = Data([3, 0, 4, 0])
        fixture.client.sendAudio(first)
        fixture.client.sendAudio(second)
        fixture.start()
        XCTAssertTrue(fixture.socket.controls.isEmpty)
        fixture.becomeReady()
        XCTAssertEqual(audio(fixture.socket), [first])
        fixture.socket.completeSend()
        XCTAssertEqual(audio(fixture.socket), [first, second])
        fixture.client.cancel()
    }

    func testNoAudioFinishDoesNotWaitForReadinessOrSendFictitiousAudio() async {
        let fixture = ElevenLabsFixture()
        fixture.start()
        let text = await fixture.client.finishAndWait()
        XCTAssertNil(text)
        XCTAssertTrue(fixture.socket.controls.isEmpty)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testUnsupportedPCMAndRateFailBeforeMalformedAudioCanBeSent() {
        let fixture = readyFixture()
        fixture.client.sendAudio(Data([1]))
        XCTAssertEqual(fixture.events.errors.first as? ElevenLabsStreamingError, .invalidPCM)
        XCTAssertTrue(fixture.socket.controls.isEmpty)
        for rate in [12_345, 0, Int.min, Int.max] {
            let factory = AssemblyAISocketFactory()
            let events = AssemblyAITestEvents()
            let client = ElevenLabsLiveClient(apiKey: "test", sampleRate: rate, makeConnection: { factory.make($0) })
            client.start(onTranscript: { _, _ in }, onError: { events.fail($0) })
            XCTAssertEqual(events.errors.first as? ElevenLabsStreamingError, .invalidSampleRate(rate))
            XCTAssertTrue(factory.sockets.isEmpty)
        }
    }

    func testCompletedSegmentDeadlinesCannotFailTheNextPendingCommit() async {
        let fixture = readyFixture()
        fixture.commit("Repeated.")
        let oldDeadlines = fixture.clock.drain()
        fillSegment(fixture)
        oldDeadlines.forEach { $0() }
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertTrue(fixture.client.isConnected)
        fixture.socket.completeSend()
        fixture.socket.emit(final("Repeated."))
        let text = await fixture.client.finishAndWait()
        XCTAssertEqual(text, "Repeated. Repeated.")
        XCTAssertEqual(commits(fixture.socket), 2)
    }

    func testUnexpectedLiveFinalFailsInsteadOfInventingAcknowledgementCorrelation() {
        let fixture = readyFixture()
        fixture.socket.emit(final("Unowned."))
        XCTAssertEqual(fixture.events.errors.first as? ElevenLabsStreamingError, .unexpectedCompletion)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }
}

private extension ElevenLabsManualCommitTests {
    func readyFixture() -> ElevenLabsFixture {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        return fixture
    }

    func fillSegment(_ fixture: ElevenLabsFixture) {
        let expected = commits(fixture.socket) + 1
        for _ in 0..<4 {
            fixture.client.sendAudio(Data(repeating: 0, count: 160_000))
            fixture.socket.completeSend()
        }
        XCTAssertEqual(commits(fixture.socket), expected)
    }

    func final(_ text: String) -> String {
        #"{"message_type":"committed_transcript","text":"\#(text)"}"#
    }

    func timestamp(_ text: String) -> String {
        #"{"message_type":"committed_transcript_with_timestamps","text":"\#(text)","words":[]}"#
    }

    func commits(_ socket: AssemblyAITestSocket) -> Int {
        socket.objects.filter { ($0["commit"] as? Bool) == true }.count
    }

    func audio(_ socket: AssemblyAITestSocket) -> [Data] {
        socket.objects.compactMap {
            guard let base64 = $0["audio_base_64"] as? String, !base64.isEmpty else { return nil }
            return Data(base64Encoded: base64)
        }
    }
}
