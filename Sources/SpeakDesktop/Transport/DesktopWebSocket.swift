import Foundation

/// SHA-1, used only for the RFC 6455 `Sec-WebSocket-Accept` value, which the
/// protocol fixes to SHA-1. Nothing secret goes through it.
enum DesktopWebSocketSHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var state: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        let bitLength = UInt64(message.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var words = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: padded.count, by: 64) {
            for index in 0..<16 {
                let offset = chunk + index * 4
                words[index] = UInt32(padded[offset]) << 24 | UInt32(padded[offset + 1]) << 16
                    | UInt32(padded[offset + 2]) << 8 | UInt32(padded[offset + 3])
            }
            for index in 16..<80 {
                let mixed = words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16]
                words[index] = mixed << 1 | mixed >> 31
            }
            var work = state
            for index in 0..<80 {
                let mixed = mix(index, work[1], work[2], work[3])
                let rotated = work[0] << 5 | work[0] >> 27
                let temp = rotated &+ mixed &+ work[4] &+ words[index]
                work = [temp, work[0], work[1] << 30 | work[1] >> 2, work[2], work[3]]
            }
            for index in 0..<5 { state[index] &+= work[index] }
        }
        return state.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32(24 - $0 * 8)) } }
    }

    /// FIPS 180-4's f(t) of words B, C and D plus the round constant K(t).
    private static func mix(_ index: Int, _ second: UInt32, _ third: UInt32, _ fourth: UInt32) -> UInt32 {
        switch index {
        case 0..<20: return ((second & third) | (~second & fourth)) &+ 0x5A82_7999
        case 20..<40: return (second ^ third ^ fourth) &+ 0x6ED9_EBA1
        case 40..<60: return ((second & third) | (second & fourth) | (third & fourth)) &+ 0x8F1B_BCDC
        default: return (second ^ third ^ fourth) &+ 0xCA62_C1D6
        }
    }
}

/// The server side of the RFC 6455 opening handshake.
package enum DesktopWebSocketHandshake {
    /// Requests longer than this without a blank line are refused.
    package static let maxRequestBytes = 8 * 1024
    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    package enum Failure: Error, Equatable {
        case tooLarge
        case notWebSocket
    }

    /// The parsed request: the client's key and how many bytes of the buffer
    /// it used. Bytes after that are already WebSocket frames.
    package struct Request: Equatable {
        package let key: String
        package let consumed: Int
    }

    /// The request in `buffer`, `nil` while its header is incomplete, or a
    /// failure when it is not a WebSocket upgrade.
    package static func parse(_ buffer: Data) throws -> Request? {
        let bytes = Array(buffer)
        guard let end = headerEnd(bytes) else {
            if bytes.count > maxRequestBytes { throw Failure.tooLarge }
            return nil
        }
        guard end <= maxRequestBytes,
              let header = String(bytes: bytes[0..<end], encoding: .utf8) else { throw Failure.tooLarge }
        var lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[0] == "GET", requestLine[2].hasPrefix("HTTP/1.1") else {
            throw Failure.notWebSocket
        }
        var fields: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let connectionTokens = (fields["connection"] ?? "").lowercased()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields["upgrade"]?.lowercased() == "websocket", connectionTokens.contains("upgrade"),
              fields["sec-websocket-version"] == "13",
              let key = fields["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 else {
            throw Failure.notWebSocket
        }
        return Request(key: key, consumed: end + 4)
    }

    /// The `Sec-WebSocket-Accept` value for a client key.
    package static func acceptValue(for key: String) -> String {
        Data(DesktopWebSocketSHA1.hash(Array((key + guid).utf8))).base64EncodedString()
    }

    /// The 101 response that completes the handshake.
    package static func response(for request: Request) -> Data {
        Data((
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(acceptValue(for: request.key))\r\n\r\n"
        ).utf8)
    }

    /// A plain refusal for a request that is not a WebSocket upgrade.
    package static let badRequest = Data(
        "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8
    )

    private static func headerEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4)
        where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index
        }
        return nil
    }
}

/// One WebSocket message or control frame from the client.
package enum DesktopWebSocketEvent: Equatable {
    case message(Data)
    case ping(Data)
    case pong
    case close
}

/// Decodes masked client frames into whole messages (RFC 6455 section 5).
/// Text and binary messages both arrive as bytes; the phone sends binary.
package struct DesktopWebSocketDecoder {
    package enum Failure: Error, Equatable {
        case protocolViolation
        case messageTooLarge
    }

    private var buffer: [UInt8] = []
    private var fragments: [UInt8] = []
    private var assembling = false

    package init() {}

    package mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    /// The next whole event, `nil` until one has arrived, or a failure that
    /// must close the connection. A message larger than `maxMessageBytes`
    /// fails before its payload is buffered.
    package mutating func next(maxMessageBytes: Int) throws -> DesktopWebSocketEvent? {
        while true {
            guard let header = try frameHeader(maxMessageBytes: maxMessageBytes) else { return nil }
            let total = header.payloadOffset + header.length
            guard buffer.count >= total else { return nil }
            let mask = Array(buffer[(header.payloadOffset - 4)..<header.payloadOffset])
            var payload = Array(buffer[header.payloadOffset..<total])
            for index in payload.indices { payload[index] ^= mask[index % 4] }
            buffer.removeFirst(total)
            if let event = try event(opcode: header.opcode, final: header.final, payload: payload) { return event }
        }
    }

    private struct FrameHeader {
        let final: Bool
        let opcode: UInt8
        let length: Int
        let payloadOffset: Int
    }

    private func frameHeader(maxMessageBytes: Int) throws -> FrameHeader? {
        guard buffer.count >= 2 else { return nil }
        let final = buffer[0] & 0x80 != 0
        let opcode = buffer[0] & 0x0F
        // No extensions are negotiated, and every client frame must be masked.
        guard buffer[0] & 0x70 == 0, buffer[1] & 0x80 != 0 else { throw Failure.protocolViolation }
        var length = UInt64(buffer[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = UInt64(buffer[2]) << 8 | UInt64(buffer[3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = buffer[2..<10].reduce(0) { $0 << 8 | UInt64($1) }
            offset = 10
        }
        if opcode & 0x08 != 0 {
            guard final, length <= 125 else { throw Failure.protocolViolation }
        } else if length > UInt64(maxMessageBytes) || UInt64(fragments.count) + length > UInt64(maxMessageBytes) {
            throw Failure.messageTooLarge
        }
        return FrameHeader(final: final, opcode: opcode, length: Int(length), payloadOffset: offset + 4)
    }

    private mutating func event(opcode: UInt8, final: Bool, payload: [UInt8]) throws -> DesktopWebSocketEvent? {
        switch opcode {
        case 0x0:
            guard assembling else { throw Failure.protocolViolation }
            fragments.append(contentsOf: payload)
            guard final else { return nil }
            let message = Data(fragments)
            fragments = []
            assembling = false
            return .message(message)
        case 0x1, 0x2:
            guard !assembling else { throw Failure.protocolViolation }
            if final { return .message(Data(payload)) }
            assembling = true
            fragments = payload
            return nil
        case 0x8: return .close
        case 0x9: return .ping(Data(payload))
        case 0xA: return .pong
        default: throw Failure.protocolViolation
        }
    }
}

/// Encodes unmasked server frames.
package enum DesktopWebSocketEncoder {
    package static func binary(_ payload: Data) -> Data { frame(opcode: 0x2, payload: payload) }
    package static func pong(_ payload: Data) -> Data { frame(opcode: 0xA, payload: payload) }
    /// A close frame with status 1000 (normal) or another code.
    package static func close(code: UInt16 = 1000) -> Data {
        frame(opcode: 0x8, payload: Data([UInt8(code >> 8), UInt8(code & 0xFF)]))
    }

    static func frame(opcode: UInt8, payload: Data) -> Data {
        var bytes: [UInt8] = [0x80 | opcode]
        switch payload.count {
        case 0...125:
            bytes.append(UInt8(payload.count))
        case 126...0xFFFF:
            bytes.append(126)
            bytes.append(UInt8(payload.count >> 8))
            bytes.append(UInt8(payload.count & 0xFF))
        default:
            bytes.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: length >> UInt64(shift)))
            }
        }
        return Data(bytes) + payload
    }
}
