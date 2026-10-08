import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// A spurious ENOTCONN re-arms the receive instead of ending the run; one that
/// persists is a failed transport. Only a real peer close frame proves normal
/// closure, even when the client has already sent its close command.
final class CartesiaLiveSpuriousDisconnectTests: XCTestCase {
    private static let notConnected = NSError(domain: NSPOSIXErrorDomain, code: 57)
    private static let retry = IgnoredReceiveFailureWindow.retryDelay

    func testSpuriousDisconnectRearmsTheReceive() {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        defer { fixture.client.cancel() }
        fixture.socket.closeByPeer(Self.notConnected)
        XCTAssertFalse(fixture.socket.isReceiving)
        fixture.clock.fire(Self.retry)
        XCTAssertTrue(fixture.socket.isReceiving)
        fixture.socket.turnUpdate("still here")
        XCTAssertEqual(fixture.log.entries, [.transcript("still here", final: false)])
        XCTAssertEqual(fixture.socket.cancels, 0)
    }

    func testPersistentDisconnectWhileRecordingIsAStalledTransport() {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        for _ in 0..<200 where fixture.log.errors.isEmpty {
            fixture.socket.closeByPeer(Self.notConnected)
            fixture.clock.fire(Self.retry)
        }
        XCTAssertEqual(fixture.log.entries, [.error("transportStalled(provider: \"Cartesia\")")])
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testPersistentDisconnectAfterTheCloseCommandReportsErrorBeforeFinish() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Kept.")
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        await fixture.waitForHeldClose()
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.closeCommands, 1)
        for _ in 0..<200 where fixture.socket.cancels == 0 {
            fixture.socket.closeByPeer(Self.notConnected)
            fixture.clock.fire(Self.retry)
        }
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
        XCTAssertEqual(fixture.log.errors.count, 1)
        XCTAssertEqual((fixture.log.errors.first as NSError?)?.domain, NSPOSIXErrorDomain)
        XCTAssertEqual((fixture.log.errors.first as NSError?)?.code, 57)
        XCTAssertEqual(Array(fixture.log.entries.suffix(2)), [
            .error(CartesiaEventLog.describe(Self.notConnected)), .finished("Kept.")
        ])
    }

    func testPostCloseDeadlineCannotHideAnUnrecoveredReceiveFailure() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        await fixture.waitForHeldClose()
        fixture.socket.completeSend()
        fixture.socket.turn("Kept.")
        fixture.socket.closeByPeer(Self.notConnected)
        // The finish deadline can arrive before the retry window expires.
        fixture.clock.fire(CartesiaLiveFixture.postClose)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
        XCTAssertEqual(fixture.log.entries, [
            .transcript("Kept.", final: true), .error(CartesiaEventLog.describe(Self.notConnected)), .finished("Kept.")
        ])
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testSuccessfulReadClearsSpuriousFailureBeforeThePostCloseDeadline() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        await fixture.waitForHeldClose()
        fixture.socket.completeSend()
        fixture.socket.closeByPeer(Self.notConnected)
        fixture.clock.fire(Self.retry)
        fixture.socket.turn("Recovered.")
        fixture.clock.fire(CartesiaLiveFixture.postClose)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Recovered.")
        XCTAssertEqual(fixture.log.entries, [.finished("Recovered.")])
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testRealNormalCloseAfterSpuriousFailureStillCompletesSuccessfully() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        await fixture.waitForHeldClose()
        fixture.socket.completeSend()
        fixture.socket.turn("Kept.")
        fixture.socket.closeByPeer(Self.notConnected)
        fixture.clock.fire(Self.retry)
        fixture.socket.closeNormally()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
        XCTAssertEqual(fixture.log.entries, [.finished("Kept.")])
        XCTAssertEqual(fixture.socket.cancels, 1)
    }
}
