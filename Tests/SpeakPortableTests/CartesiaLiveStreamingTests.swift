import Foundation
import XCTest
@testable import SpeakCore

/// Startup, readiness, framing, bounded admission and turn delivery for the
/// shared Cartesia client, driven through a scripted transport.
final class CartesiaLiveStreamingTests: XCTestCase {
    func testAudioWaitsForTheActualHandshakeThenLeavesOneFrameAtATimeInCaptureOrder() {
        let fixture = CartesiaLiveFixture()
        fixture.start()
        defer { fixture.client.cancel() }
        let frames = (1...3).map { CartesiaLiveFixture.frame(UInt8($0)) }
        frames.forEach(fixture.client.sendAudio)
        XCTAssertTrue(fixture.socket.sent.isEmpty, "Nothing leaves before the socket reports its handshake")

        fixture.socket.open()
        XCTAssertEqual(fixture.socket.binary, [frames[0]])
        XCTAssertEqual(fixture.socket.pendingCompletions, 1, "Exactly one frame is in flight")
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.binary, Array(frames[0...1]))
        fixture.socket.completeSend()
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.binary, frames)
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testConnectedFrameAlsoProvesTheSocketIsOpen() {
        let fixture = CartesiaLiveFixture()
        fixture.start()
        defer { fixture.client.cancel() }
        fixture.client.sendAudio(CartesiaLiveFixture.frame(7))
        fixture.socket.connected()
        XCTAssertEqual(fixture.socket.binary, [CartesiaLiveFixture.frame(7)])
        fixture.socket.open()
        XCTAssertEqual(fixture.socket.binary.count, 1, "A second open signal must not send twice")
    }

    func testAudioOfferedBeforeStartIsReplayedFirstAndInOrder() {
        let fixture = CartesiaLiveFixture()
        fixture.useSynchronousSends()
        let early = [CartesiaLiveFixture.frame(1), CartesiaLiveFixture.frame(2)]
        early.forEach(fixture.client.sendAudio)
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
        fixture.start()
        defer { fixture.client.cancel() }
        fixture.client.sendAudio(CartesiaLiveFixture.frame(3))
        fixture.socket.open()
        XCTAssertEqual(fixture.socket.binary, early + [CartesiaLiveFixture.frame(3)])
    }

    func testStartupAudioKeepsTheNewestTwoSecondsWhileTheHandshakeIsPending() {
        let fixture = CartesiaLiveFixture()
        fixture.useSynchronousSends()
        fixture.start()
        defer { fixture.client.cancel() }
        // Twenty-one 100 ms frames while the handshake is pending: the oldest makes room.
        let frames = (0..<21).map { CartesiaLiveFixture.frame(UInt8($0)) }
        frames.forEach(fixture.client.sendAudio)
        XCTAssertTrue(fixture.log.errors.isEmpty, "Startup audio is trimmed, not failed")
        fixture.socket.open()
        XCTAssertEqual(fixture.socket.binary, Array(frames.dropFirst()))
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testStartupTrimCountsThePartialFrameTheFramerHolds() {
        let fixture = CartesiaLiveFixture()
        fixture.useSynchronousSends()
        fixture.start()
        defer { fixture.client.cancel() }
        let frames = (0..<20).map { CartesiaLiveFixture.frame(UInt8($0)) }
        frames.forEach(fixture.client.sendAudio)
        fixture.client.sendAudio(Data(repeating: 20, count: 3_199))
        fixture.socket.open()
        XCTAssertEqual(fixture.socket.binary, Array(frames.dropFirst()))
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testCaptureChunksAreRepackedIntoHundredMillisecondFrames() {
        let fixture = CartesiaLiveFixture()
        fixture.useSynchronousSends()
        fixture.startAndOpen()
        defer { fixture.client.cancel() }
        let chunks = (0..<25).map { index in Data((0..<320).map { UInt8(truncatingIfNeeded: index + $0) }) }
        chunks.forEach(fixture.client.sendAudio)
        XCTAssertEqual(fixture.socket.binary.map(\.count), [3_200, 3_200], "Half a frame waits for more audio")
        XCTAssertEqual(fixture.socket.binary.reduce(Data(), +), chunks.prefix(20).reduce(Data(), +))
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testOnlyCompletedSendsReleaseTheTwoSecondBacklog() {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        defer { fixture.client.cancel() }
        for index in 0..<20 { fixture.client.sendAudio(CartesiaLiveFixture.frame(UInt8(index))) }
        XCTAssertTrue(fixture.log.errors.isEmpty)
        fixture.socket.completeSend()
        fixture.client.sendAudio(CartesiaLiveFixture.frame(20))
        XCTAssertTrue(fixture.log.errors.isEmpty, "A completed frame makes room for exactly one more")
        fixture.client.sendAudio(CartesiaLiveFixture.frame(21))
        XCTAssertEqual(fixture.log.entries, [.error("transportStalled(provider: \"Cartesia\")")])
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testAudioBeforeStartIsReplayedIntactUpToTwoSeconds() {
        let fixture = CartesiaLiveFixture()
        fixture.useSynchronousSends()
        let frames = (0..<20).map { CartesiaLiveFixture.frame(UInt8($0)) }
        frames.forEach(fixture.client.sendAudio)
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
        fixture.startAndOpen()
        defer { fixture.client.cancel() }
        XCTAssertEqual(fixture.socket.binary, frames)
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testEmptyChunksAreIgnored() {
        let fixture = CartesiaLiveFixture()
        for _ in 0..<1_000 { fixture.client.sendAudio(Data()) }
        fixture.useSynchronousSends()
        fixture.startAndOpen()
        defer { fixture.client.cancel() }
        for _ in 0..<1_000 { fixture.client.sendAudio(Data()) }
        XCTAssertTrue(fixture.socket.sent.isEmpty)
        fixture.client.sendAudio(CartesiaLiveFixture.frame(1))
        XCTAssertEqual(fixture.socket.binary, [CartesiaLiveFixture.frame(1)])
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testPartialSampleChunksBeforeStartAreCarriedIntoTheNextFrame() {
        let fixture = CartesiaLiveFixture()
        fixture.useSynchronousSends()
        fixture.client.sendAudio(CartesiaLiveFixture.frame(1))
        fixture.client.sendAudio(Data([1, 2, 3]))
        fixture.client.sendAudio(CartesiaLiveFixture.frame(2))
        fixture.startAndOpen()
        defer { fixture.client.cancel() }
        XCTAssertEqual(fixture.socket.binary, [
            CartesiaLiveFixture.frame(1), Data([1, 2, 3]) + CartesiaLiveFixture.frame(2, count: 3_197)
        ])
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testPartialSampleIsHeldForTheNextChunkInsteadOfMisaligningTheStream() {
        let fixture = CartesiaLiveFixture()
        fixture.useSynchronousSends()
        fixture.startAndOpen()
        defer { fixture.client.cancel() }
        fixture.client.sendAudio(Data(repeating: 1, count: 3_201))
        XCTAssertEqual(fixture.socket.binary, [Data(repeating: 1, count: 3_200)])
        fixture.client.sendAudio(Data(repeating: 2, count: 3_199))
        XCTAssertEqual(fixture.socket.binary.last, Data([1]) + Data(repeating: 2, count: 3_199))
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testSynchronousSendCompletionsDrainWithoutRecursion() {
        let fixture = CartesiaLiveFixture()
        fixture.useSynchronousSends()
        fixture.start()
        defer { fixture.client.cancel() }
        // Two seconds of 20 ms chunks: twenty 100 ms frames once repacked.
        let chunks = (0..<200).map { index in Data((0..<320).map { UInt8(truncatingIfNeeded: index + $0) }) }
        chunks.forEach(fixture.client.sendAudio)
        fixture.socket.open()
        XCTAssertEqual(fixture.socket.binary.count, 20)
        XCTAssertEqual(fixture.socket.binary.reduce(Data(), +), chunks.reduce(Data(), +))
        XCTAssertEqual(fixture.socket.maximumSendDepth, 1, "Each frame is sent from the pump loop, not a completion")
        fixture.client.sendAudio(CartesiaLiveFixture.frame(1))
        XCTAssertEqual(fixture.socket.binary.count, 21)
    }

    func testBufferedServerFramesAreDrainedIteratively() {
        let fixture = CartesiaLiveFixture()
        let events = (0..<300).map { CartesiaTestSocket.eventJSON(["type": "turn.end", "transcript": "Turn \($0)."]) }
        fixture.factory.configure { $0.preload(events) }
        fixture.start()
        defer { fixture.client.cancel() }
        XCTAssertEqual(fixture.log.transcripts.count, 300)
        XCTAssertEqual(fixture.log.transcripts.last, .transcript("Turn 299.", final: true))
        XCTAssertEqual(fixture.socket.maximumReceiveDepth, 1, "Synchronous receives must not recurse")
        XCTAssertTrue(fixture.socket.isReceiving, "The loop keeps one receive armed")
    }

    func testInterimsReplaceWithinATurnAndEveryEndedTurnIsDeliveredOnce() {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        defer { fixture.client.cancel() }
        fixture.socket.turnStart()
        fixture.socket.turnUpdate("Hel")
        fixture.socket.turnUpdate("Hello")
        fixture.socket.turnEagerEnd("Hello.")
        fixture.socket.turnResume()
        fixture.socket.turnUpdate("Hello. Yes")
        fixture.socket.turnEnd("Hello. Yes.")
        // Identical text in a new turn is a genuine repeat, not a resend.
        fixture.socket.turn("Yes.")
        fixture.socket.turn("Yes.")
        fixture.socket.turnStart()
        fixture.socket.turnUpdate("   ")
        fixture.socket.turnEnd("")
        XCTAssertEqual(fixture.log.transcripts, [
            .transcript("Hel", final: false), .transcript("Hello", final: false),
            .transcript("Hello.", final: false), .transcript("Hello. Yes", final: false),
            .transcript("Hello. Yes.", final: true),
            .transcript("Yes.", final: false), .transcript("Yes.", final: true),
            .transcript("Yes.", final: false), .transcript("Yes.", final: true)
        ])
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testConnectedUnknownAndMalformedFramesAreNotTranscripts() {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        defer { fixture.client.cancel() }
        fixture.socket.connected()
        fixture.socket.emit(#"{"type":"turn.metrics","value":1}"#)
        fixture.socket.emit("not json")
        fixture.socket.emitBinary(Data(CartesiaTestSocket.eventJSON(["type": "turn.end", "transcript": "Bin."]).utf8))
        XCTAssertEqual(fixture.log.entries, [.transcript("Bin.", final: true)])
    }

    func testServerErrorEndsTheRunOnceAndLateFramesAreIgnored() {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Kept.")
        fixture.socket.serverError(status: 429, code: "rate_limited", message: "Slow down")
        fixture.socket.turn("Late.")
        XCTAssertEqual(fixture.log.entries, [
            .transcript("Kept.", final: false), .transcript("Kept.", final: true),
            .error("Cartesia(429): Slow down")
        ])
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testHandshakeThatNeverCompletesFailsAtTheReadyDeadline() {
        let fixture = CartesiaLiveFixture()
        fixture.start()
        fixture.client.sendAudio(CartesiaLiveFixture.frame(1))
        fixture.clock.fire(CartesiaLiveClient.readyDeadline)
        XCTAssertEqual(fixture.log.errors.first as? CartesiaStreamingError, .sessionNotReady)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testStalledSendFailsAtTheSendDeadline() {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.client.sendAudio(CartesiaLiveFixture.frame(1))
        fixture.clock.fire(CartesiaLiveClient.sendDeadline)
        XCTAssertEqual(fixture.log.entries, [.error("transportStalled(provider: \"Cartesia\")")])
    }
}

extension CartesiaLiveFixture {
    /// Every socket this fixture creates completes sends synchronously.
    func useSynchronousSends() { factory.configure { $0.setSendMode(.synchronous) } }
}
