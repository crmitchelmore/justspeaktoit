import Foundation
@testable import SpeakCore
@testable import SpeakDesktop
import XCTest

// Fakes and a loopback phone for DesktopTransportReceiverTests.

/// A client frame, masked as RFC 6455 requires.
func maskedWebSocketFrame(opcode: UInt8, payload: Data, final: Bool = true) -> Data {
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

final class TransportTestVault: @unchecked Sendable {
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

final class TransportTestDeliveries: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DesktopTransportDelivery] = []

    func append(_ delivery: DesktopTransportDelivery) { lock.withLock { items.append(delivery) } }

    func wait(count: Int) -> [DesktopTransportDelivery] {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, lock.withLock({ items.count }) < count { Thread.sleep(forTimeInterval: 0.02) }
        return lock.withLock { items }
    }
}

struct TransportTestAnnouncement {
    let name: String
    let type: String
    let port: UInt16
}

final class TransportFakeAdvertiser: DesktopTransportAdvertiser, @unchecked Sendable {
    private let lock = NSLock()
    private var record: TransportTestAnnouncement?
    private var didStop = false
    /// The name a network collision would make the responder announce instead.
    var renamedTo: String?

    var published: TransportTestAnnouncement? { lock.withLock { record } }
    var stopped: Bool { lock.withLock { didStop } }

    func start(name: String, type: String, port: UInt16) throws -> String {
        lock.withLock { record = TransportTestAnnouncement(name: name, type: type, port: port) }
        return renamedTo ?? name
    }

    func stop() { lock.withLock { didStop = true } }
}

struct TransportFakeEndpoints {
    let advertiser = TransportFakeAdvertiser()

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
struct TransportLoopbackPhone {
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
        let header = try XCTUnwrap(String(bytes: inbound[..<end.lowerBound], encoding: .utf8))
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
        try send(.hello(
            HelloMessage(deviceName: "Loopback iPhone", deviceId: "loopback-phone", releaseTrain: .current)
        ))
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
        XCTAssertTrue(connection.write(maskedWebSocketFrame(opcode: 0x2, payload: payload)))
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
