import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// The shared Gemini client while it streams: setup first, audio only once the
/// session is ready, one frame in flight, bounded admission and deadlines, and
/// live delivery of the server's interims and finals.
final class GeminiLiveStreamingTests: XCTestCase {
    private typealias Fixture = GeminiLiveFixture

    func testSetupIsTheFirstFrameAndAudioWaitsForSetupComplete() {
        let fixture = Fixture()
        fixture.client.sendAudio(Fixture.frame(1))
        fixture.start()
        fixture.client.sendAudio(Fixture.frame(2))
        XCTAssertTrue(fixture.socket.sent.isEmpty, "Nothing moves before the handshake")

        fixture.socket.open()
        XCTAssertEqual(fixture.socket.kinds, ["setup"])
        fixture.socket.completeSend()
        fixture.client.sendAudio(Fixture.frame(3))
        XCTAssertEqual(fixture.socket.kinds, ["setup"], "Audio waits for the session, not for the socket")

        fixture.socket.setupComplete()
        XCTAssertEqual(fixture.socket.audio, [Fixture.frame(1)], "One frame is in flight at a time")
        fixture.socket.completeSend()
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.audio, (1...3).map { Fixture.frame(UInt8($0)) }, "Capture order is kept")
        XCTAssertTrue(fixture.log.entries.isEmpty)
    }

    func testSetupCompleteBeforeTheSetupSendCompletesStillReleasesAudioInOrder() {
        let fixture = Fixture()
        fixture.start()
        fixture.socket.open()
        fixture.client.sendAudio(Fixture.frame(1))
        fixture.socket.setupComplete()
        XCTAssertEqual(fixture.socket.kinds, ["setup"], "The setup is still the one frame in flight")
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.audio, [Fixture.frame(1)])
    }

    func testInterimsAndFinalsReachTheHostLiveAndIdenticalFinalsAreKept() {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.interim("Yes")
        fixture.socket.final("Yes.")
        fixture.socket.final("Yes.")
        fixture.socket.emitBinary(Data(GeminiTestSocket.finalJSON("Binary too.").utf8))
        XCTAssertEqual(fixture.log.entries, [
            .transcript("Yes", final: false), .transcript("Yes.", final: true), .transcript("Yes.", final: true),
            .transcript("Binary too.", final: true)
        ])
    }

    func testMalformedAndUnrelatedFramesChangeNothing() {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.emit("{ not json")
        fixture.socket.emit(#"{"usageMetadata":{"totalTokenCount":3}}"#)
        fixture.socket.emit(#"{"serverContent":{"outputTranscription":{"text":"assistant"}}}"#)
        fixture.socket.final("Still here.")
        XCTAssertEqual(fixture.log.entries, [.transcript("Still here.", final: true)])
        XCTAssertEqual(fixture.socket.cancels, 0)
    }

    func testServerErrorEnvelopeEndsTheSessionWithItsMappedError() {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.serverError(code: 429, status: "RESOURCE_EXHAUSTED")
        XCTAssertEqual(fixture.log.entries, [.error(#"rateLimited("Synthetic failure")"#)])
        XCTAssertEqual(fixture.socket.cancels, 1)
        fixture.client.sendAudio(Fixture.frame(1))
        XCTAssertTrue(fixture.socket.audio.isEmpty, "A failed session takes no more audio")
    }

    func testRejectedKeyIsReportedAsTheSharedInvalidKeyError() {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.serverError(code: 401, status: "UNAUTHENTICATED")
        let error = fixture.log.errors.first as? StreamingClientError
        guard case StreamingClientError.invalidAPIKey(let provider)? = error else {
            return XCTFail("Expected the shared invalid-key error, got \(fixture.log.entries)")
        }
        XCTAssertEqual(provider, "Google Gemini")
    }

    func testMissingKeyFailsAtStartWithoutOpeningASocket() {
        let fixture = Fixture(key: "  ")
        fixture.start()
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
        let error = fixture.log.errors.first as? StreamingClientError
        guard case StreamingClientError.missingAPIKey(let provider)? = error else {
            return XCTFail("Expected the shared missing-key error, got \(fixture.log.entries)")
        }
        XCTAssertEqual(provider, "Google Gemini")
    }

    func testSessionThatNeverAnswersItsSetupFailsAtTheReadyDeadline() {
        let fixture = Fixture()
        fixture.start()
        fixture.socket.open()
        fixture.socket.completeSend()
        fixture.clock.fire(GeminiLiveClient.readyDeadline)
        XCTAssertEqual(fixture.log.entries, [.error("sessionNotReady")])
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testReadySessionIsUnaffectedByItsReadyDeadline() {
        let fixture = Fixture()
        fixture.startReady()
        fixture.clock.fire(GeminiLiveClient.readyDeadline)
        XCTAssertTrue(fixture.log.entries.isEmpty)
    }

    func testSendThatNeverCompletesIsAStalledTransport() {
        let fixture = Fixture()
        fixture.startReady()
        fixture.client.sendAudio(Fixture.frame(1))
        fixture.clock.fire(GeminiLiveClient.sendDeadline)
        XCTAssertEqual(fixture.log.entries, [.error(#"transportStalled(provider: "Google Gemini")"#)])
    }

    func testAdmissionIsBoundedAndOverflowIsReportedNotTrimmed() {
        let fixture = Fixture()
        fixture.start()
        let frames = Int(GeminiLiveClient.bufferedAudioSeconds * 10)
        for index in 0..<frames { fixture.client.sendAudio(Fixture.frame(UInt8(index))) }
        XCTAssertTrue(fixture.log.entries.isEmpty, "Five seconds of 100 ms frames fit while the session sets up")
        fixture.client.sendAudio(Fixture.frame(0xFF))
        XCTAssertEqual(fixture.log.entries, [.error(#"transportStalled(provider: "Google Gemini")"#)])
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testPartialSamplesAreRefusedVisibly() {
        let fixture = Fixture()
        fixture.startReady()
        fixture.client.sendAudio(Data([1, 2, 3]))
        XCTAssertEqual(fixture.log.entries, [.error("invalidPCM")])
    }

    func testFailedAdmissionBeforeStartIsReportedByStart() {
        let fixture = Fixture()
        fixture.client.sendAudio(Data([1]))
        fixture.start()
        XCTAssertEqual(fixture.log.entries, [.error("invalidPCM")])
        XCTAssertTrue(fixture.factory.sockets.isEmpty, "A start that has already failed opens nothing")
    }

    /// A transport that completes sends inside `send` and answers receives
    /// from a buffer must neither recurse nor reorder.
    func testSynchronousTransportNeitherRecursesNorReorders() {
        let fixture = Fixture()
        fixture.factory.configure { $0.setSendMode(.synchronous) }
        let frames = (0..<40).map { Fixture.frame(UInt8($0)) }
        frames.forEach(fixture.client.sendAudio)
        fixture.start()
        fixture.socket.open()
        fixture.socket.preload((0..<200).map { GeminiTestSocket.interimJSON("word \($0)") })
        fixture.socket.setupComplete()
        XCTAssertEqual(fixture.socket.audio, frames)
        XCTAssertEqual(fixture.socket.maximumSendDepth, 1)
        XCTAssertEqual(fixture.socket.maximumReceiveDepth, 1)
        XCTAssertEqual(fixture.log.entries, (0..<200).map { GeminiEventLog.Entry.transcript("word \($0)", final: false) })
    }

    func testLateCallbacksOfAStoppedRunNeverReachTheNextOne() {
        let fixture = Fixture()
        fixture.factory.configure { $0.keepCallbacksAfterCancel() }
        fixture.startReady()
        let first = fixture.socket
        fixture.client.sendAudio(Fixture.frame(1))
        fixture.client.stop()
        XCTAssertEqual(first.cancels, 1)

        fixture.start()
        let second = fixture.factory.sockets[1]
        first.open()
        first.completeSend()
        first.final("From the old run.")
        second.open()
        XCTAssertEqual(second.kinds, ["setup"])
        XCTAssertTrue(fixture.log.entries.isEmpty, "Cancellation is not a failure, and old frames are ignored")
    }
}
