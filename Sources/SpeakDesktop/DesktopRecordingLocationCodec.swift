import Foundation

enum DesktopRecordingLocationCodec {
    static let maximumBytes = 16_384
    private static let magic = Data("JSTILOC1".utf8)

    struct Binding: Equatable, Sendable {
        let id: UUID
        let history: URL
        let historyIdentity: DesktopRecordingLocationIdentity
        let namespaceIdentity: DesktopRecordingLocationIdentity
    }

    enum Payload: Sendable {
        case header
        case registration(DesktopRecordingLocationRegistration)
        case ownership(DesktopRecordingLocationOwnership)
    }

    struct Envelope: Sendable {
        let binding: Binding
        let payload: Payload

        var filename: String {
            switch payload {
            case .header: return "registry.jloc"
            case let .registration(value): return "registration-\(value.id.uuidString).jloc"
            case let .ownership(value): return "ownership-\(value.recordingID.uuidString).jloc"
            }
        }
    }

    static func encode(_ envelope: Envelope) throws -> Data {
        var writer = Writer(data: magic)
        writer.integer(1, bytes: 2)
        writer.integer(1, bytes: 1) // POSIX device/inode identity, not a Windows identity conversion.
        switch envelope.payload {
        case .header: writer.integer(0, bytes: 1)
        case .registration: writer.integer(1, bytes: 1)
        case .ownership: writer.integer(2, bytes: 1)
        }
        writer.uuid(envelope.binding.id)
        try writer.path(envelope.binding.history)
        try writer.identity(envelope.binding.historyIdentity)
        try writer.identity(envelope.binding.namespaceIdentity)
        switch envelope.payload {
        case .header: break
        case let .registration(value):
            guard value.history == envelope.binding.history,
                  value.historyIdentity == envelope.binding.historyIdentity else {
                throw DesktopRecordingLocationError.foreignRegistration
            }
            writer.uuid(value.id)
            try writer.path(value.root)
            try writer.identity(value.rootIdentity)
        case let .ownership(value):
            let components = value.reference.relativePath.split(separator: "/")
            guard components.count == 2, let directory = UUID(uuidString: String(components[0])),
                  components[0] == Substring(directory.uuidString),
                  components[1] == "\(value.recordingID.uuidString).wav" else {
                throw DesktopRecordingLocationError.invalidReference
            }
            writer.uuid(value.recordingID)
            writer.uuid(value.reference.locationID)
            writer.uuid(directory)
            try writer.identity(value.directoryIdentity)
            try writer.identity(value.fileIdentity)
        }
        guard writer.data.count + 4 <= maximumBytes else { throw DesktopRecordingRegistryError.budget }
        writer.integer(UInt64(checksum(writer.data)), bytes: 4)
        return writer.data
    }

    static func decode(_ data: Data) throws -> Envelope {
        guard data.count <= maximumBytes, data.count >= magic.count + 8 else {
            throw DesktopRecordingRegistryError.corrupt
        }
        let body = Data(data.dropLast(4))
        var trailer = Reader(data: Data(data.suffix(4)))
        guard try trailer.integer(bytes: 4) == UInt64(checksum(body)) else {
            throw DesktopRecordingRegistryError.corrupt
        }
        var reader = Reader(data: body)
        guard try reader.take(magic.count) == magic, try reader.integer(bytes: 2) == 1 else {
            throw DesktopRecordingRegistryError.corrupt
        }
        guard try reader.integer(bytes: 1) == 1 else { throw DesktopRecordingRegistryError.identityUnavailable }
        let kind = try reader.integer(bytes: 1)
        let binding = try Binding(
            id: reader.uuid(), history: reader.path(), historyIdentity: reader.identity(),
            namespaceIdentity: reader.identity()
        )
        let payload: Payload
        switch kind {
        case 0: payload = .header
        case 1:
            payload = try .registration(.init(
                id: reader.uuid(), root: reader.path(), history: binding.history,
                historyIdentity: binding.historyIdentity, rootIdentity: reader.identity()
            ))
        case 2:
            let id = try reader.uuid()
            let location = try reader.uuid()
            let directory = try reader.uuid()
            payload = try .ownership(.init(
                recordingID: id,
                reference: .init(locationID: location, relativePath: "\(directory.uuidString)/\(id.uuidString).wav"),
                directoryIdentity: reader.identity(), fileIdentity: reader.identity()
            ))
        default: throw DesktopRecordingRegistryError.corrupt
        }
        guard reader.offset == body.count else { throw DesktopRecordingRegistryError.corrupt }
        return Envelope(binding: binding, payload: payload)
    }

    // CRC detects accidental corruption; private held namespace verification, not this checksum, grants authority.
    private static func checksum(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0 ..< 8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb8_8320) }
        }
        return ~value
    }

    private struct Writer {
        var data: Data
        mutating func integer(_ value: UInt64, bytes: Int) {
            for index in 0 ..< bytes { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        mutating func uuid(_ value: UUID) { data.append(contentsOf: value.uuidString.utf8) }
        mutating func identity(_ value: DesktopRecordingLocationIdentity) throws {
            guard value.file != 0 else { throw DesktopRecordingRegistryError.identityUnavailable }
            integer(value.device, bytes: 8)
            integer(value.file, bytes: 8)
        }
        mutating func path(_ url: URL) throws {
            let bytes = try validatedPath(url)
            integer(UInt64(bytes.count), bytes: 2)
            data.append(bytes)
        }
    }

    private struct Reader {
        let data: Data
        var offset = 0
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - offset else { throw DesktopRecordingRegistryError.corrupt }
            defer { offset += count }
            return Data(data[offset ..< offset + count])
        }
        mutating func integer(bytes: Int) throws -> UInt64 {
            try take(bytes).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        mutating func uuid() throws -> UUID {
            guard let string = String(data: try take(36), encoding: .utf8),
                  let value = UUID(uuidString: string), value.uuidString == string else {
                throw DesktopRecordingRegistryError.corrupt
            }
            return value
        }
        mutating func identity() throws -> DesktopRecordingLocationIdentity {
            let device = try integer(bytes: 8)
            let file = try integer(bytes: 8)
            guard file != 0 else { throw DesktopRecordingRegistryError.identityUnavailable }
            return DesktopRecordingLocationIdentity(device: device, file: file)
        }
        mutating func path() throws -> URL {
            let count = try integer(bytes: 2)
            guard count > 0, count <= 4_096,
                  let path = String(data: try take(Int(count)), encoding: .utf8) else {
                throw DesktopRecordingRegistryError.corrupt
            }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard try validatedPath(url) == Data(path.utf8) else { throw DesktopRecordingRegistryError.corrupt }
            return url
        }
    }

    private static func validatedPath(_ url: URL) throws -> Data {
        let bytes = Data(url.path.utf8)
        guard url.isFileURL, url.host?.isEmpty != false, url.query == nil, url.fragment == nil,
              isAbsoluteLocalPath(url.path), !bytes.contains(0), !bytes.isEmpty, bytes.count <= 4_096,
              url.standardizedFileURL.path == url.path,
              url.pathComponents.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw DesktopRecordingRegistryError.corrupt
        }
        return bytes
    }

    private static func isAbsoluteLocalPath(_ path: String) -> Bool {
        #if os(Windows)
        // Foundation exposes drive-rooted file paths without the URL's leading slash.
        let prefix = Array(path.utf16.prefix(3))
        guard prefix.count == 3, prefix[1] == 0x3a,
              prefix[2] == 0x2f || prefix[2] == 0x5c else { return false }
        return (0x41...0x5a).contains(prefix[0]) || (0x61...0x7a).contains(prefix[0])
        #else
        return path.hasPrefix("/")
        #endif
    }
}
