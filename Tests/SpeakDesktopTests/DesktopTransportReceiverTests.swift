import Foundation
@testable import SpeakCore
@testable import SpeakDesktop
import XCTest

/// The desktop receiver's WebSocket codec, sealed state and, over a real
/// loopback socket, a phone that pairs, sends a transcript and returns with
/// its credential.
final class DesktopTransportReceiverTests: XCTestCase {
    func testHandshake_acceptsRFC6455SampleAndRejectsPlainHTTP() throws {
        XCTAssertEqual(
            DesktopWebSocketHandshake.acceptValue(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
        let request = Data(upgradeRequest().utf8) + Data([0x82])
        XCTAssertNil(try DesktopWebSocketHandshake.parse(request.prefix(20)))
        let parsed = try XCTUnwrap(try DesktopWebSocketHandshake.parse(request))
        XCTAssertEqual(parsed.key, "dGhlIHNhbXBsZSBub25jZQ==")
        XCTAssertEqual(parsed.consumed, request.count - 1)
        let response = try XCTUnwrap(String(bytes: DesktopWebSocketHandshake.response(for: parsed), encoding: .utf8))
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 101 "))
        XCTAssertTrue(response.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
        XCTAssertThrowsError(try DesktopWebSocketHandshake.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
        XCTAssertThrowsError(try DesktopWebSocketHandshake.parse(Data(repeating: 65, count: 9000)))
    }

    func testDecoder_joinsFragmentsAnswersControlFramesAndEnforcesLimits() throws {
        var decoder = DesktopWebSocketDecoder()
        decoder.append(maskedWebSocketFrame(opcode: 0x2, payload: Data("hel".utf8), final: false))
        decoder.append(maskedWebSocketFrame(opcode: 0x9, payload: Data("p".utf8)))
        decoder.append(maskedWebSocketFrame(opcode: 0x0, payload: Data("lo".utf8)))
        let large = Data(repeating: 7, count: 70_000)
        decoder.append(maskedWebSocketFrame(opcode: 0x2, payload: large))
        decoder.append(maskedWebSocketFrame(opcode: 0x8, payload: Data()))
        XCTAssertEqual(try decoder.next(maxMessageBytes: 100_000), .ping(Data("p".utf8)))
        XCTAssertEqual(try decoder.next(maxMessageBytes: 100_000), .message(Data("hello".utf8)))
        XCTAssertEqual(try decoder.next(maxMessageBytes: 100_000), .message(large))
        XCTAssertEqual(try decoder.next(maxMessageBytes: 100_000), .close)
        XCTAssertNil(try decoder.next(maxMessageBytes: 100_000))

        var oversize = DesktopWebSocketDecoder()
        oversize.append(maskedWebSocketFrame(opcode: 0x2, payload: Data(repeating: 1, count: 5000)).prefix(8))
        XCTAssertThrowsError(try oversize.next(maxMessageBytes: 4096)) {
            XCTAssertEqual($0 as? DesktopWebSocketDecoder.Failure, .messageTooLarge)
        }
        var unmasked = DesktopWebSocketDecoder()
        unmasked.append(DesktopWebSocketEncoder.binary(Data("x".utf8)))
        XCTAssertThrowsError(try unmasked.next(maxMessageBytes: 4096)) {
            XCTAssertEqual($0 as? DesktopWebSocketDecoder.Failure, .protocolViolation)
        }
    }

    func testStorage_sealsStateUnderVaultKeyAndFailsClosedWithoutVault() throws {
        let vault = TransportTestVault()
        let url = temporaryFile()
        let storage = vault.storage(at: url)
        XCTAssertEqual(try storage.load(), DesktopTransportReceiverState())
        let pairing = TransportReceiverPairingStore()
        let code = pairing.pairingCode
        try storage.update {
            $0.enabled = true
            $0.pairing = pairing.snapshot
        }
        XCTAssertFalse(try Data(contentsOf: url).range(of: Data(code.utf8)) != nil)
        let reloaded = try vault.storage(at: url).load()
        XCTAssertTrue(reloaded.enabled)
        XCTAssertEqual(reloaded.pairing.pairingCode, code)

        // A different keyring key cannot open the file, so it starts fresh.
        XCTAssertEqual(try TransportTestVault().storage(at: url).load(), DesktopTransportReceiverState())

        let broken = DesktopTransportReceiverStorage(
            fileURL: url, readKey: { throw DesktopTransportError("locked") }, writeKey: { _ in }
        )
        let receiver = DesktopTransportReceiver(
            storage: broken, endpoints: TransportFakeEndpoints().endpoints, deliver: { _ in }
        )
        receiver.start()
        receiver.setEnabled(true)
        guard case .unavailable = receiver.status.state else { return XCTFail("expected unavailable") }
    }

    #if canImport(Glibc) || canImport(Darwin)
    func testLoopbackPhone_pairsDeliversFinalTextAndReturnsWithCredential() throws {
        let vault = TransportTestVault()
        let url = temporaryFile()
        let fake = TransportFakeEndpoints()
        let deliveries = TransportTestDeliveries()
        let receiver = DesktopTransportReceiver(
            storage: vault.storage(at: url), endpoints: fake.endpoints, serviceName: "Test PC",
            deliver: { deliveries.append($0) }
        )
        defer { receiver.shutDown() }
        receiver.start()
        XCTAssertEqual(receiver.status.state, .off)
        XCTAssertNil(fake.advertiser.published)
        XCTAssertEqual(receiver.status.serviceName, "Test PC")

        fake.advertiser.renamedTo = "Test PC #2"
        receiver.setEnabled(true)
        XCTAssertEqual(receiver.status.state, .listening)
        let published = try XCTUnwrap(fake.advertiser.published)
        XCTAssertEqual(published.name, "Test PC")
        XCTAssertEqual(published.type, SpeakTransportServiceType)
        XCTAssertEqual(receiver.status.serviceName, "Test PC #2", "the status names what the network sees")
        let code = receiver.status.pairingCode
        XCTAssertEqual(code.count, 6)

        var phone = try TransportLoopbackPhone(port: published.port)
        let credential = try XCTUnwrap(try phone.pair(secret: .code(code)))
        try phone.authenticate(code: code)
        try phone.send(.sessionStart(SessionStartMessage(sessionId: "s1", model: "m")))
        try phone.send(.transcriptChunk(TranscriptChunkMessage(
            sessionId: "s1", sequenceNumber: 1, text: "he", isFinal: false
        )))
        guard case .ack(let partial) = try phone.receive() else { return XCTFail("expected ack") }
        try phone.send(.transcriptChunk(TranscriptChunkMessage(
            sessionId: "s1", sequenceNumber: 2, text: "hello from the phone", isFinal: true
        )))
        guard case .ack(let final) = try phone.receive() else { return XCTFail("expected ack") }
        XCTAssertEqual([partial.sequenceNumber, final.sequenceNumber], [1, 2])
        XCTAssertEqual(deliveries.wait(count: 1), [
            DesktopTransportDelivery(text: "hello from the phone", deviceName: "Loopback iPhone")
        ])
        XCTAssertEqual(receiver.status.devices.map(\.name), ["Loopback iPhone"])
        phone.close()

        var returning = try TransportLoopbackPhone(port: published.port)
        XCTAssertNil(try returning.pair(secret: .credential(credential)))
        try returning.authenticate(code: "")
        returning.close()

        receiver.shutDown()
        XCTAssertTrue(fake.advertiser.stopped)
        let saved = try vault.storage(at: url).load()
        XCTAssertTrue(saved.enabled)
        XCTAssertEqual(saved.pairing.devices.map(\.name), ["Loopback iPhone"])
        XCTAssertEqual(saved.pairing.credentials.map(\.credential.id), [credential.id])
    }

    func testLoopbackStranger_isDisconnectedWithoutPairingAndPlainHTTPIsRefused() throws {
        let vault = TransportTestVault()
        let fake = TransportFakeEndpoints()
        let receiver = DesktopTransportReceiver(
            storage: vault.storage(at: temporaryFile()), endpoints: fake.endpoints,
            unauthenticatedTimeout: 0.3, deliver: { _ in }
        )
        defer { receiver.shutDown() }
        receiver.start()
        receiver.setEnabled(true)
        let port = try XCTUnwrap(fake.advertiser.published).port

        let idle = try TransportLoopbackPhone(port: port)
        XCTAssertEqual(idle.readUntilClosed(seconds: 3), true)

        let browser = try DesktopPOSIXTransportConnection.connect(toLoopbackPort: port)
        XCTAssertTrue(browser.write(Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
        guard case .data(let reply) = browser.read(maxBytes: 4096, timeoutMilliseconds: 2000) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(try XCTUnwrap(String(bytes: reply, encoding: .utf8)).hasPrefix("HTTP/1.1 400 "))
        browser.close()

        receiver.setEnabled(false)
        XCTAssertEqual(receiver.status.state, .off)
        XCTAssertTrue(fake.advertiser.stopped)
    }
    #endif

    #if canImport(Network)
    /// The iPhone's real client (Network.framework WebSocket plus CryptoKit)
    /// pairs with the desktop receiver and sends a transcript.
    func testAppleTransportChannel_pairsAndSendsToDesktopReceiver() async throws {
        let fake = TransportFakeEndpoints()
        let deliveries = TransportTestDeliveries()
        let receiver = DesktopTransportReceiver(
            storage: TransportTestVault().storage(at: temporaryFile()), endpoints: fake.endpoints,
            deliver: { deliveries.append($0) }
        )
        defer { receiver.shutDown() }
        receiver.start()
        receiver.setEnabled(true)
        let port = try XCTUnwrap(fake.advertiser.published).port
        let code = receiver.status.pairingCode

        let endpoint = try XCTUnwrap(SpeakTransportWire.endpoint(host: "127.0.0.1", port: port))
        let channel = TransportChannel.connecting(to: endpoint, includesPeerToPeer: false)
        defer { channel.close() }
        try await channel.start()
        let issued = try await channel.establishSecureSession(secret: .code(code))
        XCTAssertNotNil(issued)
        try await channel.send(.hello(
            HelloMessage(deviceName: "Real iPhone", deviceId: "real", releaseTrain: .current)
        ))
        try await channel.send(.authenticate(AuthenticateMessage(pairingCode: code)))
        guard case .authResult(let result) = try await channel.receive() else { return XCTFail("expected auth") }
        XCTAssertTrue(result.success)
        await channel.admitSessionFrames()
        try await channel.send(.transcriptChunk(TranscriptChunkMessage(
            sessionId: "s1", sequenceNumber: 1, text: "sent by the Apple client", isFinal: true
        )))
        guard case .ack(let ack) = try await channel.receive() else { return XCTFail("expected ack") }
        XCTAssertEqual(ack.sequenceNumber, 1)
        XCTAssertEqual(deliveries.wait(count: 1).map(\.text), ["sent by the Apple client"])
    }
    #endif

    // MARK: - Helpers

    private func upgradeRequest() -> String {
        "GET /speak HTTP/1.1\r\nHost: test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    }

    private func temporaryFile() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("phone-receiver.sealed")
    }
}
