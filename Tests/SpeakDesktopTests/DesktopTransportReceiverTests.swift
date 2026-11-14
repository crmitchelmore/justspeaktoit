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
        let response = String(decoding: DesktopWebSocketHandshake.response(for: parsed), as: UTF8.self)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 101 "))
        XCTAssertTrue(response.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
        XCTAssertThrowsError(try DesktopWebSocketHandshake.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
        XCTAssertThrowsError(try DesktopWebSocketHandshake.parse(Data(repeating: 65, count: 9000)))
    }

    func testDecoder_joinsFragmentsAnswersControlFramesAndEnforcesLimits() throws {
        var decoder = DesktopWebSocketDecoder()
        decoder.append(maskedFrame(opcode: 0x2, payload: Data("hel".utf8), final: false))
        decoder.append(maskedFrame(opcode: 0x9, payload: Data("p".utf8)))
        decoder.append(maskedFrame(opcode: 0x0, payload: Data("lo".utf8)))
        let large = Data(repeating: 7, count: 70_000)
        decoder.append(maskedFrame(opcode: 0x2, payload: large))
        decoder.append(maskedFrame(opcode: 0x8, payload: Data()))
        XCTAssertEqual(try decoder.next(maxMessageBytes: 100_000), .ping(Data("p".utf8)))
        XCTAssertEqual(try decoder.next(maxMessageBytes: 100_000), .message(Data("hello".utf8)))
        XCTAssertEqual(try decoder.next(maxMessageBytes: 100_000), .message(large))
        XCTAssertEqual(try decoder.next(maxMessageBytes: 100_000), .close)
        XCTAssertNil(try decoder.next(maxMessageBytes: 100_000))

        var oversize = DesktopWebSocketDecoder()
        oversize.append(maskedFrame(opcode: 0x2, payload: Data(repeating: 1, count: 5000)).prefix(8))
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
        let vault = VaultBox()
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
        XCTAssertEqual(try VaultBox().storage(at: url).load(), DesktopTransportReceiverState())

        let broken = DesktopTransportReceiverStorage(
            fileURL: url, readKey: { throw DesktopTransportError("locked") }, writeKey: { _ in }
        )
        let receiver = DesktopTransportReceiver(
            storage: broken, endpoints: FakeEndpoints().endpoints, deliver: { _ in }
        )
        receiver.start()
        receiver.setEnabled(true)
        guard case .unavailable = receiver.status.state else { return XCTFail("expected unavailable") }
    }

    #if canImport(Glibc) || canImport(Darwin)
    func testLoopbackPhone_pairsDeliversFinalTextAndReturnsWithCredential() throws {
        let vault = VaultBox()
        let url = temporaryFile()
        let fake = FakeEndpoints()
        let deliveries = DeliveryBox()
        let receiver = DesktopTransportReceiver(
            storage: vault.storage(at: url), endpoints: fake.endpoints, serviceName: "Test PC",
            deliver: { deliveries.append($0) }
        )
        defer { receiver.shutDown() }
        receiver.start()
        XCTAssertEqual(receiver.status.state, .off)
        XCTAssertNil(fake.advertiser.published)

        receiver.setEnabled(true)
        XCTAssertEqual(receiver.status.state, .listening)
        let published = try XCTUnwrap(fake.advertiser.published)
        XCTAssertEqual(published.name, "Test PC")
        XCTAssertEqual(published.type, SpeakTransportServiceType)
        let code = receiver.status.pairingCode
        XCTAssertEqual(code.count, 6)

        var phone = try LoopbackPhone(port: published.port)
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

        var returning = try LoopbackPhone(port: published.port)
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
        let vault = VaultBox()
        let fake = FakeEndpoints()
        let receiver = DesktopTransportReceiver(
            storage: vault.storage(at: temporaryFile()), endpoints: fake.endpoints,
            unauthenticatedTimeout: 0.3, deliver: { _ in }
        )
        defer { receiver.shutDown() }
        receiver.start()
        receiver.setEnabled(true)
        let port = try XCTUnwrap(fake.advertiser.published).port

        let idle = try LoopbackPhone(port: port)
        XCTAssertEqual(idle.readUntilClosed(seconds: 3), true)

        let browser = try DesktopPOSIXTransportConnection.connect(toLoopbackPort: port)
        XCTAssertTrue(browser.write(Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
        guard case .data(let reply) = browser.read(maxBytes: 4096, timeoutMilliseconds: 2000) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(String(decoding: reply, as: UTF8.self).hasPrefix("HTTP/1.1 400 "))
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
        let fake = FakeEndpoints()
        let deliveries = DeliveryBox()
        let receiver = DesktopTransportReceiver(
            storage: VaultBox().storage(at: temporaryFile()), endpoints: fake.endpoints,
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
        try await channel.send(.hello(HelloMessage(deviceName: "Real iPhone", deviceId: "real", releaseTrain: .current)))
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

/// A client frame, masked as RFC 6455 requires.
private func maskedFrame(opcode: UInt8, payload: Data, final: Bool = true) -> Data {
    var bytes: [UInt8] = [(final ? 0x80 : 0) | opcode]
    if payload.count <= 125 {
        bytes.append(0x80 | UInt8(payload.count))
    } else if payload.count <= 0xFFFF {
        bytes += [UInt8(0x80 | 126), UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
    } else {
        bytes.append(0x80 | 127)
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: payload.count >> shift))
        }
    }
    let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
    bytes += mask
    bytes += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
    return Data(bytes)
}

private final class VaultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?

    func storage(at url: URL) -> DesktopTransportReceiverStorage {
        DesktopTransportReceiverStorage(
            fileURL: url,
            readKey: { [self] in lock.withLock { key } },
            writeKey: { [self] value in lock.withLock { key = value } }
        )
    }
}

private final class DeliveryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DesktopTransportDelivery] = []

    func append(_ delivery: DesktopTransportDelivery) { lock.withLock { items.append(delivery) } }

    func wait(count: Int) -> [DesktopTransportDelivery] {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, lock.withLock({ items.count }) < count { Thread.sleep(forTimeInterval: 0.02) }
        return lock.withLock { items }
    }
}

private final class FakeAdvertiser: DesktopTransportAdvertiser, @unchecked Sendable {
    private let lock = NSLock()
    private var record: (name: String, type: String, port: UInt16)?
    private var didStop = false

    var published: (name: String, type: String, port: UInt16)? { lock.withLock { record } }
    var stopped: Bool { lock.withLock { didStop } }

    func start(name: String, type: String, port: UInt16) throws {
        lock.withLock { record = (name, type, port) }
    }

    func stop() { lock.withLock { didStop = true } }
}

private struct FakeEndpoints {
    let advertiser = FakeAdvertiser()

    var endpoints: DesktopTransportEndpoints {
        let advertiser = advertiser
        return DesktopTransportEndpoints(
            makeListener: {
                #if canImport(Glibc) || canImport(Darwin)
                return try DesktopPOSIXTransportListener(loopbackOnly: true)
                #else
                throw DesktopTransportError("no POSIX sockets")
                #endif
            },
            makeAdvertiser: { advertiser }
        )
    }
}

#if canImport(Glibc) || canImport(Darwin)
/// The phone's side over a real socket: WebSocket client framing plus the
/// portable client handshake the iOS sender's protocol uses.
private struct LoopbackPhone {
    private let connection: DesktopPOSIXTransportConnection
    private var inbound = Data()
    private var keys: TransportPortableSessionKeys?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(port: UInt16) throws {
        connection = try DesktopPOSIXTransportConnection.connect(toLoopbackPort: port)
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET /speak HTTP/1.1\r\nHost: test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        XCTAssertTrue(connection.write(Data(request.utf8)))
        while inbound.range(of: Data("\r\n\r\n".utf8)) == nil { try fill() }
        let end = try XCTUnwrap(inbound.range(of: Data("\r\n\r\n".utf8)))
        let header = String(decoding: inbound[..<end.lowerBound], as: UTF8.self)
        XCTAssertTrue(header.hasPrefix("HTTP/1.1 101 "))
        XCTAssertTrue(header.contains(DesktopWebSocketHandshake.acceptValue(for: key)))
        inbound = Data(inbound[end.upperBound...])
    }

    /// Runs the encrypted handshake and returns any credential issued.
    mutating func pair(secret: TransportPairingSecret) throws -> TransportDeviceCredential? {
        let client = try TransportPortableClientHandshake(secret: secret)
        try sendFrame(client.frame)
        var finish = try client.finish(serverFrame: try receiveFrame())
        try sendFrame(finish.finished)
        let confirmation = try finish.keys.inbound.open(try receiveFrame())
        keys = finish.keys
        return try TransportHandshakeLabel.credential(inServerFinished: confirmation)
    }

    mutating func authenticate(code: String) throws {
        try send(.hello(HelloMessage(deviceName: "Loopback iPhone", deviceId: "loopback-phone", releaseTrain: .current)))
        try send(.authenticate(AuthenticateMessage(pairingCode: code)))
        guard case .authResult(let result) = try receive() else { return XCTFail("expected auth result") }
        XCTAssertTrue(result.success, result.errorMessage ?? "")
    }

    mutating func send(_ message: TransportMessage) throws {
        var keys = try XCTUnwrap(keys)
        try sendFrame(try keys.outbound.seal(try encoder.encode(message)))
        self.keys = keys
    }

    mutating func receive() throws -> TransportMessage {
        var keys = try XCTUnwrap(keys)
        let message = try decoder.decode(TransportMessage.self, from: try keys.inbound.open(try receiveFrame()))
        self.keys = keys
        return message
    }

    /// Whether the receiver closed the connection within `seconds`.
    func readUntilClosed(seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if case .closed = connection.read(maxBytes: 4096, timeoutMilliseconds: 100) { return true }
        }
        return false
    }

    func close() { connection.close() }

    private func sendFrame(_ payload: Data) throws {
        XCTAssertTrue(connection.write(maskedFrame(opcode: 0x2, payload: payload)))
    }

    private mutating func receiveFrame() throws -> Data {
        while true {
            if inbound.count >= 2 {
                let bytes = Array(inbound)
                XCTAssertEqual(bytes[1] & 0x80, 0, "server frames are unmasked")
                var length: Int? = Int(bytes[1] & 0x7F)
                var offset = 2
                if length == 126 {
                    length = bytes.count >= 4 ? Int(bytes[2]) << 8 | Int(bytes[3]) : nil
                    offset = 4
                }
                if let length, bytes.count >= offset + length {
                    inbound = Data(bytes[(offset + length)...])
                    XCTAssertEqual(bytes[0], 0x82, "expected one binary frame")
                    return Data(bytes[offset..<(offset + length)])
                }
            }
            try fill()
        }
    }

    private mutating func fill() throws {
        switch connection.read(maxBytes: 65_536, timeoutMilliseconds: 3000) {
        case .data(let data): inbound.append(data)
        case .timedOut, .closed: throw DesktopTransportError("the receiver did not reply")
        }
    }
}
#endif
