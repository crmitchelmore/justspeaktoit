import Network
import XCTest

@testable import SpeakApp
@testable import SpeakCore

/// Drives the shipping `MacConnection` client against the shipping
/// `TransportServer` over a loopback socket.
///
/// Codable-only tests cannot see a framing mismatch: before issue #688 the two
/// sides agreed on every message shape and still could not exchange one byte,
/// because the phone spoke WebSocket and the Mac read a hand-rolled length
/// prefix. These tests connect the real endpoints, so that failure mode is
/// visible in CI.
///
/// The listener binds loopback with Bonjour and peer-to-peer switched off: the
/// tests need a socket, not the local network. If the environment refuses to
/// bind a listening socket at all, they skip rather than fail.
@MainActor
final class TransportLoopbackTests: XCTestCase {
    private var server: TransportServer?
    private let codeKey = "speakTransportPairingCode"
    private let devicesKey = "speakTransportPairedDevices"
    private var savedCode: String?
    private var savedDevices: [String: String]?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        self.savedCode = defaults.string(forKey: self.codeKey)
        self.savedDevices = defaults.dictionary(forKey: self.devicesKey) as? [String: String]
        defaults.removeObject(forKey: self.codeKey)
        defaults.removeObject(forKey: self.devicesKey)
    }

    override func tearDown() {
        self.server?.stop()
        self.server = nil

        let defaults = UserDefaults.standard
        if let savedCode = self.savedCode {
            defaults.set(savedCode, forKey: self.codeKey)
        } else {
            defaults.removeObject(forKey: self.codeKey)
        }
        if let savedDevices = self.savedDevices {
            defaults.set(savedDevices, forKey: self.devicesKey)
        } else {
            defaults.removeObject(forKey: self.devicesKey)
        }
        super.tearDown()
    }

    // MARK: - Happy path

    func testPairedDevice_authenticatesAndDeliversATranscript() async throws {
        let endpoint = try await self.startServer()
        let server = try XCTUnwrap(self.server)

        let delivery = self.expectation(description: "The Mac receives the transcript")
        let inbox = TranscriptInbox()
        server.onTranscriptReceived = { sessionId, text in
            inbox.record(sessionId: sessionId, text: text)
            delivery.fulfill()
        }

        let client = MacConnection()
        await client.connect(to: endpoint, named: "Test Mac", pairingCode: PairingManager.shared.pairingCode)

        XCTAssertEqual(client.state, .connected, "Authentication must succeed over the shared framing")
        XCTAssertEqual(client.connectedMacName, "Test Mac")
        XCTAssertEqual(server.connectedDevices.count, 1, "The Mac must list the paired device")

        try await client.sendSessionStart(sessionId: "session-1", model: "test-model")
        try await client.sendTranscript(sessionId: "session-1", text: "Hello Mac", isFinal: true)

        await self.fulfillment(of: [delivery], timeout: 5)
        XCTAssertEqual(inbox.text, "Hello Mac")
        XCTAssertEqual(inbox.sessionId, "session-1")

        XCTAssertTrue(PairingManager.shared.isDevicePaired(id: DeviceIdentity.deviceId))
        client.disconnect()
    }

    // MARK: - Rejections

    func testMismatchedProtocolVersion_isRejectedWithTheTypedError() async throws {
        let endpoint = try await self.startServer()
        let server = try XCTUnwrap(self.server)

        let client = MacConnection(announcedProtocolVersion: SpeakTransportProtocolVersion + 1)
        await client.connect(to: endpoint, named: "Test Mac", pairingCode: PairingManager.shared.pairingCode)

        guard case .error(let message) = client.state else {
            XCTFail("Expected a rejection, got \(client.state)")
            return
        }
        XCTAssertTrue(message.contains("Protocol version mismatch"), "Unhelpful rejection: \(message)")
        XCTAssertTrue(message.contains("v\(SpeakTransportProtocolVersion)"), "Rejection omits the server version")
        XCTAssertTrue(server.connectedDevices.isEmpty, "A rejected client must not appear as connected")
    }

    func testWrongPairingCode_isRejectedAndNoDeviceIsPaired() async throws {
        let endpoint = try await self.startServer()
        let server = try XCTUnwrap(self.server)

        let client = MacConnection()
        await client.connect(to: endpoint, named: "Test Mac", pairingCode: "not-the-code")

        guard case .error(let message) = client.state else {
            XCTFail("Expected a rejection, got \(client.state)")
            return
        }
        XCTAssertEqual(message, "Invalid pairing code")
        XCTAssertTrue(server.connectedDevices.isEmpty)
        XCTAssertTrue(PairingManager.shared.pairedDevices.isEmpty)
    }

    func testOversizedHandshakeFrame_isRefusedBeforeAuthentication() async throws {
        let endpoint = try await self.startServer()
        let server = try XCTUnwrap(self.server)

        let channel = TransportChannel.connecting(to: endpoint, includesPeerToPeer: false)
        try await channel.start()
        // Raise only this end's ceiling: the Mac must hold its own line for a
        // peer that has not authenticated.
        await channel.admitSessionFrames()

        let padding = String(repeating: "n", count: TransportFrameLimit.handshake.maximumBytes)
        try await channel.send(.hello(HelloMessage(deviceName: padding, deviceId: "oversized-device")))

        let didClose = await self.waitForClosure(of: channel)
        XCTAssertTrue(didClose, "The Mac must hang up on an oversized handshake frame")
        XCTAssertTrue(server.connectedDevices.isEmpty)
    }

    func testTranscriptBeforeAuthentication_isDroppedAndTheConnectionCloses() async throws {
        let endpoint = try await self.startServer()
        let server = try XCTUnwrap(self.server)

        let inbox = TranscriptInbox()
        server.onTranscriptReceived = { sessionId, text in
            inbox.record(sessionId: sessionId, text: text)
        }

        let channel = TransportChannel.connecting(to: endpoint, includesPeerToPeer: false)
        try await channel.start()
        let chunk = TranscriptChunkMessage(
            sessionId: "session-1",
            sequenceNumber: 1,
            text: "text from an unpaired device",
            isFinal: true
        )
        try await channel.send(.transcriptChunk(chunk))

        let didClose = await self.waitForClosure(of: channel)
        XCTAssertTrue(didClose, "The Mac must hang up on a session frame that arrives before authentication")
        XCTAssertNil(inbox.text, "Unauthenticated text must never reach the Mac's insertion point")
    }

    // MARK: - Helpers

    private func startServer() async throws -> NWEndpoint {
        let server = TransportServer()
        self.server = server
        try server.start(on: .any, advertisesService: false)

        for _ in 0..<100 {
            if let port = server.port {
                return try XCTUnwrap(SpeakTransportWire.endpoint(host: "127.0.0.1", port: port))
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw XCTSkip("The transport listener never became ready; this environment forbids listening sockets")
    }

    /// Waits for the Mac to hang up, and reports whether it did.
    private func waitForClosure(of channel: TransportChannel, timeout: TimeInterval = 5) async -> Bool {
        let result = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await channel.receive()
                    return false
                } catch {
                    return true
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            // Unblocks whichever child is still waiting, so the group can finish.
            channel.close()
            group.cancelAll()
            return first
        }
        return result
    }
}

/// Collects what the Mac would insert, so assertions can read it after the wait.
private final class TranscriptInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSessionId: String?
    private var storedText: String?

    var sessionId: String? {
        self.lock.withLock { self.storedSessionId }
    }

    var text: String? {
        self.lock.withLock { self.storedText }
    }

    func record(sessionId: String, text: String) {
        self.lock.withLock {
            self.storedSessionId = sessionId
            self.storedText = text
        }
    }
}
