import Network
import XCTest

@testable import SpeakCore

/// Pins the wire format that both ends of "Send to Mac" are built from.
///
/// Issue #688: the phone spoke WebSocket while the Mac read a hand-rolled
/// four-byte length prefix, so the Mac read the letters of `GET ` as a frame
/// length of 1,196,314,144 bytes and waited for data that never came. Both ends
/// now build their parameters from `SpeakTransportWire`, and these tests fail if
/// that single definition stops describing WebSocket framing with a ceiling.
final class TransportFramingTests: XCTestCase {

    // MARK: - Wire format

    private func webSocketOptions(_ parameters: NWParameters) -> [NWProtocolWebSocket.Options] {
        parameters.defaultProtocolStack.applicationProtocols.compactMap { $0 as? NWProtocolWebSocket.Options }
    }

    func testParameters_frameWithWebSocket() {
        let options = self.webSocketOptions(SpeakTransportWire.parameters(includesPeerToPeer: false))
        XCTAssertEqual(options.count, 1, "The transport must be WebSocket, once, on both ends")
    }

    func testParameters_capTheMessageSizeInTheFramingLayer() {
        let options = self.webSocketOptions(SpeakTransportWire.parameters(includesPeerToPeer: true))
        XCTAssertEqual(
            options.first?.maximumMessageSize,
            TransportFrameLimit.session.maximumBytes,
            "An oversized frame must be refused before its bytes are buffered"
        )
    }

    func testParameters_answerProtocolLevelPings() {
        let options = self.webSocketOptions(SpeakTransportWire.parameters(includesPeerToPeer: true))
        XCTAssertEqual(options.first?.autoReplyPing, true)
    }

    func testParameters_offerPeerToPeerOnlyWhenAsked() {
        XCTAssertTrue(SpeakTransportWire.parameters(includesPeerToPeer: true).includePeerToPeer)
        XCTAssertFalse(SpeakTransportWire.parameters(includesPeerToPeer: false).includePeerToPeer)
    }

    // MARK: - Frame limits

    func testHandshakeLimit_isFarSmallerThanTheSessionLimit() {
        XCTAssertLessThan(
            TransportFrameLimit.handshake.maximumBytes,
            TransportFrameLimit.session.maximumBytes,
            "An unauthenticated peer must not get session capacity"
        )
        XCTAssertLessThanOrEqual(
            TransportFrameLimit.handshake.maximumBytes,
            8 * 1024,
            "The pre-authentication ceiling must stay small enough to be a real bound"
        )
    }

    func testLimit_admitsFramesUpToItsCeilingOnly() {
        let limit = TransportFrameLimit.handshake
        XCTAssertTrue(limit.admits(byteCount: 1))
        XCTAssertTrue(limit.admits(byteCount: limit.maximumBytes))
        XCTAssertFalse(limit.admits(byteCount: limit.maximumBytes + 1))
        XCTAssertFalse(limit.admits(byteCount: 0), "An empty frame carries no message")
        XCTAssertFalse(limit.admits(byteCount: -1))
    }

    func testSessionLimit_admitsARealisticTranscript() {
        // Roughly forty thousand words of dictation.
        XCTAssertTrue(TransportFrameLimit.session.admits(byteCount: 250_000))
        XCTAssertFalse(TransportFrameLimit.session.admits(byteCount: 4 * 1024 * 1024))
    }

    // MARK: - Addressing

    func testEndpoint_addressesTheMacAsAWebSocketURL() throws {
        let endpoint = try XCTUnwrap(SpeakTransportWire.endpoint(host: "192.0.2.10", port: 8080))
        guard case .url(let url) = endpoint else {
            XCTFail("A WebSocket client must address the Mac by URL or by Bonjour service")
            return
        }
        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(url.host, "192.0.2.10")
        XCTAssertEqual(url.port, 8080)
        XCTAssertEqual(url.path, SpeakTransportWire.endpointPath)
    }

    // MARK: - Channel

    /// An address nothing listens on: these tests build a channel but never
    /// connect it, because the behaviour under test happens before any I/O.
    private func unusedEndpoint() throws -> NWEndpoint {
        try XCTUnwrap(SpeakTransportWire.endpoint(host: "127.0.0.1", port: 1))
    }

    func testChannel_refusesToSendAnOversizedHandshakeFrame() async throws {
        // No server: the ceiling is checked on encode, before any byte is sent.
        let channel = TransportChannel.connecting(to: try self.unusedEndpoint(), includesPeerToPeer: false)
        defer { channel.close() }

        let ceiling = TransportFrameLimit.handshake.maximumBytes
        let hello = HelloMessage(deviceName: String(repeating: "n", count: ceiling), deviceId: "device-1")

        do {
            try await channel.send(.hello(hello))
            XCTFail("An oversized handshake frame must not be sent")
        } catch let error as TransportChannelError {
            guard case .frameTooLarge(let byteCount, let maximumBytes) = error else {
                XCTFail("Expected frameTooLarge, got \(error)")
                return
            }
            XCTAssertGreaterThan(byteCount, maximumBytes)
            XCTAssertEqual(maximumBytes, ceiling)
        }
    }

    func testChannel_startsAtTheHandshakeCeilingAndIsRaisedByAuthentication() async throws {
        let channel = TransportChannel.connecting(to: try self.unusedEndpoint(), includesPeerToPeer: false)
        defer { channel.close() }

        let before = await channel.frameLimit
        XCTAssertEqual(before, .handshake, "A new channel must not trust the peer yet")

        await channel.admitSessionFrames()
        let after = await channel.frameLimit
        XCTAssertEqual(after, .session, "Authentication is what earns session capacity")
    }

    func testChannelErrors_carryTheirNumbersInTheDescription() {
        let tooLarge = TransportChannelError.frameTooLarge(byteCount: 9, maximumBytes: 4)
        XCTAssertTrue(tooLarge.localizedDescription.contains("9"))
        XCTAssertTrue(tooLarge.localizedDescription.contains("4"))
        XCTAssertFalse(TransportChannelError.closed.localizedDescription.isEmpty)
    }
}
