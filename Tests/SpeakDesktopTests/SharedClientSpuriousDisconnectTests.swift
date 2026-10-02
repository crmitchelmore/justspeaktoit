import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// ENOTCONN ("socket is not connected") can be reported spuriously around a
/// WebSocket handshake. The shared clients re-arm their receive after one and
/// ignore a matching send failure, as the established Apple clients always
/// did, but a socket that keeps failing still ends the session.
final class SharedClientSpuriousDisconnectTests: XCTestCase {
    private static let notConnected = NSError(domain: NSPOSIXErrorDomain, code: 57)
    private static let retry = IgnoredReceiveFailureWindow.retryDelay

    func testOnlyAnUncodedNotConnectedFailureIsSpurious() {
        XCTAssertTrue(WebSocketErrorFilter.isSpuriousDisconnect(Self.notConnected))
        XCTAssertFalse(WebSocketErrorFilter.isSpuriousDisconnect(URLError(.networkConnectionLost)))
        // A close frame is the stream's real end, however the transport words it.
        XCTAssertFalse(WebSocketErrorFilter.isSpuriousDisconnect(NotConnectedClose(webSocketCloseCode: 1_011)))
        XCTAssertTrue(WebSocketErrorFilter.isSpuriousDisconnect(NotConnectedClose(webSocketCloseCode: nil)))
    }

    func testAssemblyAISpuriousDisconnectKeepsTheSessionAndTheFallback() {
        let fixture = AssemblyAILiveFixture()
        fixture.start()
        let socket = fixture.factory.sockets[0]
        socket.open()
        socket.fail(with: Self.notConnected)
        XCTAssertEqual(fixture.factory.sockets.count, 1, "A spurious disconnect never spends the fallback")
        fixture.clock.fire(Self.retry)
        socket.begin()
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        XCTAssertEqual(socket.binary.count, 1)
        socket.completeSend(Self.notConnected)
        fixture.client.sendAudio(Data(repeating: 2, count: 3_200))
        XCTAssertEqual(socket.binary.count, 2, "A spurious send failure is ignored")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(socket.cancels, 0)
        fixture.client.cancel()
    }

    func testAssemblyAIPersistentDisconnectBeforeBeginFallsBackOnce() {
        let fixture = AssemblyAILiveFixture()
        fixture.start()
        let europe = fixture.factory.sockets[0]
        europe.open()
        for _ in 0..<200 where fixture.factory.sockets.count == 1 {
            europe.fail(with: Self.notConnected)
            fixture.clock.fire(Self.retry)
        }
        XCTAssertEqual(fixture.factory.requests.map { $0.url?.host }, [
            AssemblyAIStreamingEndpoint.europe.rawValue, AssemblyAIStreamingEndpoint.global.rawValue
        ])
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
    }

    func testElevenLabsSpuriousDisconnectRearmsAndAPersistentOneStalls() {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.fail(with: Self.notConnected)
        fixture.clock.fire(Self.retry)
        fixture.socket.emit(#"{"message_type":"partial_transcript","text":"still here"}"#)
        XCTAssertEqual(fixture.events.texts, ["still here"])
        XCTAssertTrue(fixture.events.errors.isEmpty)
        for _ in 0..<200 where fixture.events.errors.isEmpty {
            fixture.socket.fail(with: Self.notConnected)
            fixture.clock.fire(Self.retry)
        }
        guard case StreamingClientError.transportStalled? = fixture.events.errors.first else {
            return XCTFail("A socket that keeps failing is a stalled transport")
        }
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testSonioxSpuriousDisconnectsOnReceiveAndSendKeepTheSession() {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.fail(with: Self.notConnected)
        fixture.clock.fire(Self.retry)
        fixture.socket.emit(#"{"tokens":[{"text":"still here","is_final":false}]}"#)
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        fixture.socket.completeSend(Self.notConnected)
        fixture.client.sendAudio(Data(repeating: 2, count: 3_200))
        XCTAssertEqual(fixture.socket.binary.count, 2, "A spurious send failure is ignored")
        XCTAssertEqual(fixture.events.texts, ["still here"])
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertTrue(fixture.client.isConnected)
        fixture.client.cancel()
    }
}

/// A lost-socket failure as a transport may describe it, with or without the
/// peer's close code.
private struct NotConnectedClose: StreamingWebSocketCloseReporting, LocalizedError {
    let webSocketCloseCode: Int?
    var errorDescription: String? { "Socket is not connected" }
}
