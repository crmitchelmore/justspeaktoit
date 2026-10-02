import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// A spurious ENOTCONN re-arms the receive instead of ending the run; one that
/// persists is a lost socket, ended as the server's closure once it has the
/// close command and as a stalled transport before then.
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

    func testPersistentDisconnectAfterTheCloseCommandEndsTheFinishAsItsClosure() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Kept.")
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.closeCommands, 1)
        for _ in 0..<200 where fixture.socket.cancels == 0 {
            fixture.socket.closeByPeer(Self.notConnected)
            fixture.clock.fire(Self.retry)
        }
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }
}
