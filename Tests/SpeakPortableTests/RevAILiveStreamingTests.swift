import Foundation
import XCTest
@testable import SpeakCore

/// Readiness, bounded admission and hypothesis delivery for the shared Rev.ai
/// client, driven through a scripted transport.
final class RevAILiveStreamingTests: XCTestCase {
    func testAudioWaitsForConnectedThenLeavesOneFrameAtATimeInCaptureOrder() {
        let fixture = RevAILiveFixture()
        fixture.start()
        defer { fixture.client.cancel() }
        let frames = (1...3).map { RevAILiveFixture.frame(UInt8($0)) }
        frames.forEach(fixture.client.sendAudio)
        fixture.socket.open()
        XCTAssertTrue(fixture.socket.sent.isEmpty, "Rev.ai rejects audio until `connected`, handshake or not")

        fixture.socket.revAIConnected()
        XCTAssertEqual(fixture.socket.binary, [frames[0]])
        XCTAssertEqual(fixture.socket.pendingCompletions, 1, "Exactly one frame is in flight")
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.binary, Array(frames[0...1]))
        fixture.socket.completeSend()
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.binary, frames)
        XCTAssertTrue(fixture.socket.texts.isEmpty, "Nothing but PCM leaves while streaming")
        XCTAssertTrue(fixture.log.entries.isEmpty)
    }

    func testConnectedAloneProvesTheHandshakeAndIsHonouredOnce() {
        let fixture = RevAILiveFixture()
        fixture.start()
        defer { fixture.client.cancel() }
        fixture.client.sendAudio(RevAILiveFixture.frame(7))
        fixture.socket.revAIConnected()
        XCTAssertEqual(fixture.socket.binary, [RevAILiveFixture.frame(7)], "A received frame proves the socket is open")
        fixture.socket.open()
        fixture.socket.revAIConnected()
        XCTAssertEqual(fixture.socket.binary.count, 1, "Neither signal sends twice")
        XCTAssertEqual(fixture.clock.pending(RevAILiveClient.readyDeadline), 1)
        fixture.clock.fire(RevAILiveClient.readyDeadline)
        XCTAssertTrue(fixture.log.entries.isEmpty, "A ready session outlives its readiness deadline")
    }

    func testAudioOfferedBeforeStartIsReplayedFirstAndInOrder() {
        let fixture = RevAILiveFixture()
        fixture.useSynchronousSends()
        let early = [RevAILiveFixture.frame(1), RevAILiveFixture.frame(2)]
        early.forEach(fixture.client.sendAudio)
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
        fixture.start()
        defer { fixture.client.cancel() }
        fixture.client.sendAudio(RevAILiveFixture.frame(3))
        fixture.socket.revAIConnected()
        XCTAssertEqual(fixture.socket.binary, early + [RevAILiveFixture.frame(3)])
    }

    func testOverflowBeforeConnectedIsReportedAsAnUnreadySessionInsteadOfTrimming() {
        let fixture = RevAILiveFixture()
        fixture.start()
        fixture.socket.open()
        // Fifty 100 ms frames fill the five-second budget while `connected` is pending.
        for index in 0..<50 { fixture.client.sendAudio(RevAILiveFixture.frame(UInt8(index))) }
        XCTAssertTrue(fixture.log.errors.isEmpty)
        fixture.client.sendAudio(RevAILiveFixture.frame(99))
        XCTAssertEqual(fixture.log.entries, [.error("sessionNotReady")])
        XCTAssertEqual(fixture.socket.cancels, 1)
        fixture.socket.revAIConnected()
        fixture.client.sendAudio(RevAILiveFixture.frame(100))
        XCTAssertTrue(fixture.socket.sent.isEmpty, "A failed run sends nothing, not even the oldest audio")
        XCTAssertEqual(fixture.log.errors.count, 1, "The overflow is reported once")
    }

    func testOverflowAfterConnectedIsAStalledTransportAndOnlyCompletionsReleaseBudget() {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        for index in 0..<50 { fixture.client.sendAudio(RevAILiveFixture.frame(UInt8(index))) }
        fixture.socket.completeSend()
        fixture.client.sendAudio(RevAILiveFixture.frame(50))
        XCTAssertTrue(fixture.log.errors.isEmpty, "A completed frame makes room for exactly one more")
        fixture.client.sendAudio(RevAILiveFixture.frame(51))
        XCTAssertEqual(fixture.log.entries, [RevAIEventLog.stalled])
        XCTAssertEqual(fixture.socket.binary.count, 2, "Nothing is evicted or sent after the overflow")
    }

    func testFrameCountBoundIncludesTheFrameInFlight() {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        defer { fixture.client.cancel() }
        for _ in 0..<RevAILiveClient.maximumQueuedFrames { fixture.client.sendAudio(Data([0, 0])) }
        XCTAssertEqual(fixture.socket.pendingCompletions, 1)
        XCTAssertTrue(fixture.log.errors.isEmpty)
        fixture.client.sendAudio(Data([0, 0]))
        XCTAssertEqual(fixture.log.entries, [RevAIEventLog.stalled])
    }

    func testRefusedAudioBeforeStartIsReportedByStartWhichOpensNothing() {
        for (refused, expected) in [(Data([1, 2, 3]), "invalidPCM"), (Data(count: 160_002), "sessionNotReady")] {
            let fixture = RevAILiveFixture()
            fixture.client.sendAudio(RevAILiveFixture.frame(1))
            fixture.client.sendAudio(refused)
            fixture.client.sendAudio(RevAILiveFixture.frame(2))
            fixture.start()
            XCTAssertTrue(fixture.factory.sockets.isEmpty, "Audio that can no longer be sent intact never connects")
            XCTAssertEqual(fixture.log.entries, [.error(expected)])
        }
    }

    func testEmptyFramesAreIgnoredAndPartialSamplesAreRefused() {
        let fixture = RevAILiveFixture()
        for _ in 0..<1_000 { fixture.client.sendAudio(Data()) }
        fixture.startAndConnect()
        for _ in 0..<1_000 { fixture.client.sendAudio(Data()) }
        XCTAssertTrue(fixture.socket.sent.isEmpty)
        XCTAssertTrue(fixture.log.entries.isEmpty, "Empty frames are neither sent nor counted")
        fixture.client.sendAudio(Data(repeating: 1, count: 3_201))
        XCTAssertTrue(fixture.socket.sent.isEmpty, "A misaligned frame is never sent")
        XCTAssertEqual(fixture.log.entries, [.error("invalidPCM")])
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testSynchronousSendCompletionsDrainWithoutRecursion() {
        let fixture = RevAILiveFixture()
        fixture.useSynchronousSends()
        fixture.start()
        defer { fixture.client.cancel() }
        let frames = (0..<200).map { index in Data((0..<320).map { UInt8(truncatingIfNeeded: index + $0) }) }
        frames.forEach(fixture.client.sendAudio)
        fixture.socket.revAIConnected()
        XCTAssertEqual(fixture.socket.binary, frames)
        XCTAssertEqual(fixture.socket.maximumSendDepth, 1, "Each frame is sent from the pump loop, not a completion")
        fixture.client.sendAudio(RevAILiveFixture.frame(1))
        XCTAssertEqual(fixture.socket.binary.count, 201)
    }

    func testBufferedServerFramesAreDrainedIteratively() {
        let fixture = RevAILiveFixture()
        let finals = (0..<300).map { index in
            CartesiaTestSocket.revAIHypothesis("final", [["type": "text", "value": "N\(index)."]])
        }
        fixture.factory.configure { $0.preload([#"{"type":"connected","id":"s1"}"#] + finals) }
        fixture.start()
        defer { fixture.client.cancel() }
        XCTAssertEqual(fixture.log.transcripts.count, 300)
        XCTAssertEqual(fixture.log.transcripts.last, .transcript("N299.", final: true))
        XCTAssertEqual(fixture.socket.maximumReceiveDepth, 1, "Synchronous receives must not recurse")
        XCTAssertTrue(fixture.socket.isReceiving, "The loop keeps one receive armed")
    }

    func testPartialsRestateTheSegmentAndEveryFinalIsDeliveredOnceInOrder() {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        defer { fixture.client.cancel() }
        fixture.socket.revAIPartial(["one"])
        fixture.socket.revAIPartial(["one", "tooth"])
        fixture.socket.emit(CartesiaTestSocket.revAIDocumentedFinal)
        // Each final covers a new window of audio, so identical text is two
        // utterances rather than a resend (issue #700).
        fixture.socket.revAIFinal("Yes.")
        fixture.socket.revAIFinal("Yes.")
        fixture.socket.revAIPartial(["um"])
        fixture.socket.revAIPartial([" "])
        fixture.socket.revAIEmptyFinal()
        XCTAssertEqual(fixture.log.entries, [
            .transcript("one", final: false), .transcript("one tooth", final: false),
            .transcript("One two.", final: true), .transcript("Yes.", final: true), .transcript("Yes.", final: true),
            .transcript("um", final: false)
        ], "Hypotheses without words are never delivered")
    }

    func testConnectedUnknownAndMalformedFramesAreNotTranscripts() {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        defer { fixture.client.cancel() }
        fixture.socket.revAIConnected()
        fixture.socket.emit(#"{"type":"something_new_upstream"}"#)
        fixture.socket.emit("not json")
        let binary = CartesiaTestSocket.revAIHypothesis("final", [["type": "text", "value": "Bin."]])
        fixture.socket.emitBinary(Data(binary.utf8))
        XCTAssertEqual(fixture.log.entries, [.transcript("Bin.", final: true)])
    }

    func testConnectedThatNeverArrivesFailsAtTheReadyDeadlineWithNothingSent() {
        let fixture = RevAILiveFixture()
        fixture.start()
        fixture.socket.open()
        fixture.client.sendAudio(RevAILiveFixture.frame(1))
        fixture.clock.fire(RevAILiveClient.readyDeadline)
        XCTAssertEqual(fixture.log.entries, [.error("sessionNotReady")])
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertTrue(fixture.socket.sent.isEmpty, "Nothing is sent before `connected`")
    }

    func testStalledSendFailsAtTheSendDeadline() {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.client.sendAudio(RevAILiveFixture.frame(1))
        fixture.clock.fire(RevAILiveClient.sendDeadline)
        XCTAssertEqual(fixture.log.entries, [RevAIEventLog.stalled])
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testMissingTokenFailsBeforeAnySocketIsOpened() {
        let fixture = RevAILiveFixture(token: "  ")
        fixture.start()
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
        XCTAssertEqual(fixture.log.entries, [.error(#"missingAPIKey(provider: "Rev.ai")"#)])
    }
}
