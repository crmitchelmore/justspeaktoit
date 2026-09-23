import Foundation
import XCTest
@testable import SpeakCore

/// Startup, readiness, bounded admission and turn delivery for the shared
/// Cartesia client, driven through a scripted transport.
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

    func testByteBudgetOverflowIsReportedInsteadOfTrimmingTheRecording() {
        let fixture = CartesiaLiveFixture()
        fixture.start()
        // Fifty 100 ms frames fill the five-second budget while the handshake is pending.
        for index in 0..<50 { fixture.client.sendAudio(CartesiaLiveFixture.frame(UInt8(index))) }
        XCTAssertTrue(fixture.log.errors.isEmpty)
        fixture.client.sendAudio(CartesiaLiveFixture.frame(99))
        XCTAssertEqual(fixture.log.entries, [.error("transportStalled(provider: \"Cartesia\")")])
        XCTAssertEqual(fixture.socket.cancels, 1)
        fixture.socket.open()
        fixture.client.sendAudio(CartesiaLiveFixture.frame(100))
        XCTAssertTrue(fixture.socket.sent.isEmpty, "A failed run sends nothing, not even the oldest audio")
        XCTAssertEqual(fixture.log.errors.count, 1, "The overflow is reported once")
    }

    func testFrameCountBoundIncludesTheFrameInFlight() {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        defer { fixture.client.cancel() }
        for _ in 0..<256 { fixture.client.sendAudio(Data([0, 0])) }
        XCTAssertEqual(fixture.socket.pendingCompletions, 1)
        XCTAssertTrue(fixture.log.errors.isEmpty)
        fixture.client.sendAudio(Data([0, 0]))
        XCTAssertEqual(fixture.log.errors.count, 1)
    }

    func testOnlyCompletedSendsReleaseBudget() {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        defer { fixture.client.cancel() }
        for index in 0..<50 { fixture.client.sendAudio(CartesiaLiveFixture.frame(UInt8(index))) }
        fixture.socket.completeSend()
        fixture.client.sendAudio(CartesiaLiveFixture.frame(50))
        XCTAssertTrue(fixture.log.errors.isEmpty, "A completed frame makes room for exactly one more")
        fixture.client.sendAudio(CartesiaLiveFixture.frame(51))
        XCTAssertEqual(fixture.log.errors.count, 1)
    }

    func testOverflowBeforeStartIsReportedByStart() {
        let fixture = CartesiaLiveFixture()
        for index in 0..<51 { fixture.client.sendAudio(CartesiaLiveFixture.frame(UInt8(index))) }
        fixture.start()
        XCTAssertTrue(fixture.factory.sockets.isEmpty, "A run that already lost audio never connects")
        XCTAssertEqual(fixture.log.entries, [.error("transportStalled(provider: \"Cartesia\")")])
    }

    func testEmptyFramesAreIgnoredAndTakeNoFrameSlots() {
        let fixture = CartesiaLiveFixture()
        for _ in 0..<1_000 { fixture.client.sendAudio(Data()) }
        fixture.startAndOpen()
        defer { fixture.client.cancel() }
        for _ in 0..<1_000 { fixture.client.sendAudio(Data()) }
        XCTAssertTrue(fixture.socket.sent.isEmpty)
        for _ in 0..<256 { fixture.client.sendAudio(Data([0, 0])) }
        XCTAssertTrue(fixture.log.errors.isEmpty, "Empty frames took none of the 256 frame slots")
    }

    func testTinyFramesBeforeStartAreBoundedByCountAndReportedByStart() {
        let fixture = CartesiaLiveFixture()
        for _ in 0..<257 { fixture.client.sendAudio(Data([0, 0])) }
        fixture.start()
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
        XCTAssertEqual(fixture.log.entries, [.error("transportStalled(provider: \"Cartesia\")")])
    }

    func testExactlyFullPreStartQueueIsReplayedIntact() {
        let fixture = CartesiaLiveFixture()
        fixture.useSynchronousSends()
        let frames = (0..<256).map { Data([UInt8(truncatingIfNeeded: $0), 0]) }
        frames.forEach(fixture.client.sendAudio)
        fixture.startAndOpen()
        defer { fixture.client.cancel() }
        XCTAssertEqual(fixture.socket.binary, frames)
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testPartialSampleFrameBeforeStartIsReportedByStart() {
        let fixture = CartesiaLiveFixture()
        fixture.client.sendAudio(CartesiaLiveFixture.frame(1))
        fixture.client.sendAudio(Data([1, 2, 3]))
        fixture.client.sendAudio(CartesiaLiveFixture.frame(2))
        fixture.start()
        XCTAssertTrue(fixture.factory.sockets.isEmpty, "Audio that can no longer be sent intact never connects")
        XCTAssertEqual(fixture.log.errors.count, 1)
        XCTAssertEqual(fixture.log.errors.first as? CartesiaStreamingError, .invalidPCM)
    }

    func testPartialSampleFrameIsRefusedBeforeItMisalignsTheStream() {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.client.sendAudio(Data(repeating: 1, count: 3_201))
        XCTAssertTrue(fixture.socket.sent.isEmpty)
        XCTAssertEqual(fixture.log.errors.first as? CartesiaStreamingError, .invalidPCM)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testSynchronousSendCompletionsDrainWithoutRecursion() {
        let fixture = CartesiaLiveFixture()
        fixture.useSynchronousSends()
        fixture.start()
        defer { fixture.client.cancel() }
        let frames = (0..<200).map { index in Data((0..<320).map { UInt8(truncatingIfNeeded: index + $0) }) }
        frames.forEach(fixture.client.sendAudio)
        fixture.socket.open()
        XCTAssertEqual(fixture.socket.binary, frames)
        XCTAssertEqual(fixture.socket.maximumSendDepth, 1, "Each frame is sent from the pump loop, not a completion")
        fixture.client.sendAudio(CartesiaLiveFixture.frame(1))
        XCTAssertEqual(fixture.socket.binary.count, 201)
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
            .error(#"server(statusCode: Optional(429), code: Optional("rate_limited"), message: "Slow down")"#)
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
