import Foundation
import XCTest
@testable import SpeakCore

/// Every way a shared Rev.ai stream can end other than the normal close after
/// `EOS`: each publishes an error, and a finish returns only confirmed words.
final class RevAIFailureTests: XCTestCase {
    func testGenericClosureAfterEOS_isAnIncompleteSessionNeverASuccess() async {
        let fixture = RevAILiveFixture()
        let finish = await finishingAfterEOS(fixture)
        fixture.socket.finalHypothesis("Kept.")
        fixture.socket.fail()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed. Kept.", "A trailing final still counts as confirmed words")
        XCTAssertEqual(fixture.events.errors.map { $0 as? RevAILiveError }, [.missingCompletion])
        XCTAssertEqual(fixture.events.texts, ["Confirmed."], "Finals during the finish are returned, not delivered")
    }

    func testCloseFramesWithoutTheNormalCodeAfterEOS_fail() async {
        let cases: [(Int?, Error)] = [
            (nil, RevAILiveError.missingCompletion),
            (1_001, RevAIStreamingError.closed(closeCode: 1_001)),
            (1_005, RevAIStreamingError.closed(closeCode: 1_005)),
            (1_006, RevAIStreamingError.closed(closeCode: 1_006)),
            (1_011, RevAIStreamingError.closed(closeCode: 1_011)),
            (4_003, RevAIStreamingError.insufficientCredits)
        ]
        for (code, expected) in cases {
            let fixture = RevAILiveFixture()
            let finish = await finishingAfterEOS(fixture)
            fixture.socket.peerClose(code)
            let transcript = await finish.value
            XCTAssertEqual(transcript, "Confirmed.", String(describing: code))
            XCTAssertEqual(fixture.events.errors.count, 1, String(describing: code))
            XCTAssertEqual(fixture.events.errors.first?.localizedDescription, expected.localizedDescription)
        }
    }

    func testNormalCloseBeforeEOS_isAnUnexpectedCompletion() async {
        let fixture = RevAILiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.stream([RevAILiveFixture.frame(0)])
        fixture.socket.finalHypothesis("Early.")
        fixture.socket.peerClose(1_000)
        XCTAssertEqual(fixture.events.errors.map { $0 as? RevAILiveError }, [.unexpectedCompletion])
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Early.")
        XCTAssertTrue(fixture.socket.endOfStreamFrames.isEmpty)
    }

    func testDocumentedCloseCodes_surfaceTheirOwnErrors() {
        let cases: [(Int, Error, Bool)] = [
            (4_001, StreamingClientError.invalidAPIKey(provider: "Rev.ai"), false),
            (4_002, RevAIStreamingError.badRequest, false),
            (4_013, RevAIStreamingError.temporarilyUnavailable(closeCode: 4_013), false),
            (4_029, RevAIStreamingError.tooManyConnections, false),
            (4_003, RevAIStreamingError.insufficientCredits, true),
            (4_010, RevAIStreamingError.temporarilyUnavailable(closeCode: 4_010), true),
            (1_007, RevAIStreamingError.closed(closeCode: 1_007), true)
        ]
        for (code, expected, midStream) in cases {
            let fixture = RevAILiveFixture()
            fixture.start()
            fixture.socket.open()
            if midStream {
                fixture.socket.connected()
                fixture.stream([RevAILiveFixture.frame(0)])
            }
            fixture.socket.peerClose(code)
            XCTAssertEqual(fixture.events.errors.count, 1, "\(code)")
            XCTAssertEqual(fixture.events.errors.first?.localizedDescription, expected.localizedDescription, "\(code)")
            if code == 4_001 {
                guard case .invalidAPIKey? = fixture.events.errors.first as? StreamingClientError else {
                    return XCTFail("4001 must point the user at the key")
                }
            }
            XCTAssertEqual(fixture.socket.cancels, 1)
        }
    }

    func testFinishDeadline_namesTheStageItCaught() async {
        // Never connected: the capture could not be sent at all.
        let unready = RevAILiveFixture()
        unready.start()
        unready.socket.open()
        unready.client.sendAudio(RevAILiveFixture.frame(0))
        await expireFinish(unready, expecting: RevAILiveError.sessionNotReady)
        // Connected, but the drain never completed.
        let stalled = RevAILiveFixture()
        stalled.start()
        stalled.becomeReady()
        stalled.client.sendAudio(RevAILiveFixture.frame(0))
        await expireFinish(stalled, expecting: StreamingClientError.transportStalled(provider: "Rev.ai"))
        // `EOS` left and was written, but no close confirmed the trailing hypothesis.
        let silent = RevAILiveFixture()
        silent.start()
        silent.becomeReady()
        silent.stream([RevAILiveFixture.frame(0)])
        await expireFinish(silent, expecting: RevAILiveError.missingCompletion) { fixture in
            await fixture.settle { !fixture.socket.endOfStreamFrames.isEmpty }
            fixture.socket.completeSend()
        }
    }

    func testReadinessDeadline_failsAStartThatNeverConnects() {
        let fixture = RevAILiveFixture()
        fixture.start()
        fixture.socket.open()
        fixture.client.sendAudio(RevAILiveFixture.frame(0))
        fixture.clock.fire(RevAILiveClient.readyDeadline)
        XCTAssertEqual(fixture.events.errors.map { $0 as? RevAILiveError }, [.sessionNotReady])
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertTrue(fixture.socket.binary.isEmpty, "Nothing is sent before `connected`")
    }

    func testFailedSend_defersToTheReceiveSideWhichNamesTheClose() {
        let fixture = RevAILiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(RevAILiveFixture.frame(0))
        fixture.client.sendAudio(RevAILiveFixture.frame(1))
        fixture.socket.completeSend(URLError(.networkConnectionLost))
        XCTAssertTrue(fixture.events.errors.isEmpty, "The receive side reports the cause")
        XCTAssertEqual(fixture.socket.binary, [RevAILiveFixture.frame(0)], "Nothing more is sent after a failure")
        fixture.socket.peerClose(4_003)
        XCTAssertEqual(fixture.events.errors.map { $0 as? RevAIStreamingError }, [.insufficientCredits])
        fixture.clock.fire(RevAILiveClient.sendFailureGrace)
        XCTAssertEqual(fixture.events.errors.count, 1, "The grace of a settled run is inert")
    }

    func testFailedSendThatTheReceiveNeverReflects_publishesItsOwnErrorAfterTheGrace() {
        let fixture = RevAILiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(RevAILiveFixture.frame(0))
        fixture.socket.completeSend(URLError(.cannotWriteToFile))
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.clock.fire(RevAILiveClient.sendFailureGrace)
        XCTAssertEqual((fixture.events.errors.first as? URLError)?.code, .cannotWriteToFile)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testByteBound_failsVisiblyOnceWithoutEvictingAnyAdmittedAudio() {
        let fixture = RevAILiveFixture()
        fixture.start()
        fixture.becomeReady()
        // Five seconds of 16 kHz PCM16: 50 frames of 100 ms, one of them in flight.
        (0..<50).forEach { fixture.client.sendAudio(RevAILiveFixture.frame($0)) }
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 50)
        fixture.client.sendAudio(RevAILiveFixture.frame(50))
        fixture.client.sendAudio(RevAILiveFixture.frame(51))
        XCTAssertEqual(fixture.events.errors.count, 1, "The overflow is reported once")
        guard case .transportStalled? = fixture.events.errors.first as? StreamingClientError else {
            return XCTFail("A stalled transport is reported, not absorbed")
        }
        XCTAssertEqual(fixture.socket.binary, [RevAILiveFixture.frame(0)])
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testFrameBound_catchesTinyFramesBeforeTheByteBound() {
        let fixture = RevAILiveFixture()
        fixture.start()
        for index in 0..<RevAILiveClient.maximumBufferedFrames {
            fixture.client.sendAudio(RevAILiveFixture.frame(index, count: 2))
        }
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.client.preroll.snapshot.chunkCount, RevAILiveClient.maximumBufferedFrames)
        fixture.client.sendAudio(RevAILiveFixture.frame(0, count: 2))
        XCTAssertEqual(fixture.events.errors.map { $0 as? RevAILiveError }, [.sessionNotReady],
                       "Audio outgrowing its bound before `connected` means the session is not coming")
    }

    func testOddLengthPCM_failsTheRunAndEmptyFramesAreIgnored() {
        let fixture = RevAILiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Data())
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertTrue(fixture.socket.binary.isEmpty)
        fixture.client.sendAudio(Data(repeating: 1, count: 3))
        XCTAssertEqual(fixture.events.errors.map { $0 as? RevAILiveError }, [.invalidPCM])
        XCTAssertTrue(fixture.socket.binary.isEmpty, "A misaligned frame is never sent")
    }

    func testPreStartAudio_isHeldUnderTheSameBoundsAndLeadsTheStream() {
        let fixture = RevAILiveFixture()
        let held = (0..<3).map { RevAILiveFixture.frame($0) }
        held.forEach(fixture.client.sendAudio)
        XCTAssertEqual(fixture.client.preroll.snapshot, StreamingAudioPreroll.Snapshot(
            chunkCount: 3, byteCount: 9_600, droppedChunkCount: 0
        ))
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(RevAILiveFixture.frame(3))
        (0..<4).forEach { _ in fixture.socket.completeSend() }
        XCTAssertEqual(fixture.socket.binary, held + [RevAILiveFixture.frame(3)])
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
    }

    func testPreStartRefusals_areReportedByTheNextStartInsteadOfDropped() {
        let cases: [(Data, RevAILiveError)] = [
            (Data(repeating: 1, count: 3), .invalidPCM),
            (Data(repeating: 1, count: 160_002), .overflowBeforeStart)
        ]
        for (refused, expected) in cases {
            let fixture = RevAILiveFixture()
            fixture.client.sendAudio(RevAILiveFixture.frame(0))
            fixture.client.sendAudio(refused)
            fixture.client.sendAudio(RevAILiveFixture.frame(1))
            XCTAssertTrue(fixture.client.preroll.isEmpty, "A partial opening is never kept")
            fixture.start()
            XCTAssertEqual(fixture.events.errors.map { $0 as? RevAILiveError }, [expected])
            XCTAssertTrue(fixture.factory.sockets.isEmpty, "A refused start opens no socket")
        }
    }

    func testMissingTokenAndUndocumentedRate_failBeforeAnySocketIsOpened() {
        let missing = RevAILiveFixture(token: "  ")
        missing.start()
        guard case .missingAPIKey(let provider)? = missing.events.errors.first as? StreamingClientError else {
            return XCTFail("Expected a missing-key error")
        }
        XCTAssertEqual(provider, "Rev.ai")
        let rate = RevAILiveFixture(sampleRate: 96_000)
        rate.start()
        XCTAssertEqual(rate.events.errors.map { $0 as? RevAIStreamingError }, [.badRequest])
        XCTAssertTrue(missing.factory.sockets.isEmpty)
        XCTAssertTrue(rate.factory.sockets.isEmpty)
    }
}

private extension RevAIFailureTests {
    /// A started, connected run that streamed one frame, received one final,
    /// and whose finish has handed `EOS` to the transport and seen it written.
    func finishingAfterEOS(_ fixture: RevAILiveFixture) async -> Task<String?, Never> {
        fixture.start()
        fixture.becomeReady()
        fixture.stream([RevAILiveFixture.frame(0)])
        fixture.socket.finalHypothesis("Confirmed.")
        let endOfStream = expectation(description: "EOS handed to the transport")
        fixture.socket.fulfillOnEndOfStream(endOfStream)
        let client = fixture.client
        let finish = Task { await client.finishAndWait() }
        await fulfillment(of: [endOfStream], timeout: 2)
        fixture.socket.completeSend()
        return finish
    }

    /// Finishes, lets the one whole-finish deadline expire, and checks that its
    /// error was published before the finish returned the confirmed text.
    func expireFinish(
        _ fixture: RevAILiveFixture, expecting expected: Error,
        beforeExpiry: (RevAILiveFixture) async -> Void = { _ in }
    ) async {
        let client = fixture.client
        let finish = Task { () -> (String?, Int) in
            let transcript = await client.finishAndWait()
            return (transcript, fixture.events.errors.count)
        }
        await fixture.waitForFinishWaiters()
        await beforeExpiry(fixture)
        fixture.clock.fire(RevAIStreaming.finishBudget)
        let (transcript, errorsAtReturn) = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(errorsAtReturn, 1, "The error is published before the finish returns")
        XCTAssertEqual(fixture.events.errors.first?.localizedDescription, expected.localizedDescription)
    }
}
