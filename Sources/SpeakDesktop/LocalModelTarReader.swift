import Foundation

/// Streaming reader for the tar subset used by pinned model archives: POSIX
/// ustar or GNU headers describing directories and regular files only.
///
/// Links, devices, FIFOs, pax/GNU extension records and sparse files are
/// refused by name. Header checksums, zero padding, the two-block end marker
/// and an all-zero trailer are enforced. Entry metadata such as modes and
/// owners is ignored, never applied.
final class LocalModelTarReader {
    struct Entry: Equatable {
        enum Kind: Equatable { case directory, file }
        let kind: Kind
        let components: [String]
        let size: Int64
    }

    private enum State {
        case header
        case data(remaining: Int64, padding: Int)
        case padding(Int)
        case endMarker
        case trailer
    }

    private static let blockSize = 512
    private var state: State = .header
    private var block: [UInt8] = []
    private let onEntry: (Entry) throws -> Void
    private let onData: (UnsafeRawBufferPointer) throws -> Void
    private let onEntryEnd: () throws -> Void
    private(set) var consumedBytes: Int64 = 0

    init(
        onEntry: @escaping (Entry) throws -> Void,
        onData: @escaping (UnsafeRawBufferPointer) throws -> Void,
        onEntryEnd: @escaping () throws -> Void
    ) {
        self.onEntry = onEntry
        self.onData = onData
        self.onEntryEnd = onEntryEnd
        block.reserveCapacity(Self.blockSize)
    }

    func consume(_ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let rest = UnsafeRawBufferPointer(rebasing: bytes[offset...])
            switch state {
            case .data(let remaining, let padding):
                let count = Int(min(remaining, Int64(rest.count)))
                try onData(UnsafeRawBufferPointer(rebasing: rest[0..<count]))
                offset += count
                if remaining == Int64(count) {
                    try onEntryEnd()
                    state = padding > 0 ? .padding(padding) : .header
                } else {
                    state = .data(remaining: remaining - Int64(count), padding: padding)
                }
            case .padding(let remaining):
                let count = min(remaining, rest.count)
                guard rest[0..<count].allSatisfy({ $0 == 0 }) else { throw LocalModelArchiveError.corruptHeader("padding") }
                offset += count
                state = remaining == count ? .header : .padding(remaining - count)
            case .trailer:
                guard rest.allSatisfy({ $0 == 0 }) else { throw LocalModelArchiveError.trailingData }
                offset = bytes.count
            case .header, .endMarker:
                offset += try accumulate(rest)
            }
        }
        consumedBytes += Int64(bytes.count)
    }

    /// Call once the decompressed stream has ended.
    func finish() throws {
        guard case .trailer = state, block.isEmpty else { throw LocalModelArchiveError.truncated }
        guard consumedBytes % Int64(Self.blockSize) == 0 else { throw LocalModelArchiveError.trailingData }
    }

    private func accumulate(_ bytes: UnsafeRawBufferPointer) throws -> Int {
        let count = min(Self.blockSize - block.count, bytes.count)
        block.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[0..<count]))
        guard block.count == Self.blockSize else { return count }
        let header = block
        block.removeAll(keepingCapacity: true)
        let isZero = header.allSatisfy { $0 == 0 }
        if case .endMarker = state {
            guard isZero else { throw LocalModelArchiveError.corruptHeader("incomplete end marker") }
            state = .trailer
            return count
        }
        guard !isZero else {
            state = .endMarker
            return count
        }
        let entry = try header.withUnsafeBytes { try Self.parse($0) }
        try onEntry(entry)
        if entry.size > 0 {
            let remainder = Int(entry.size % Int64(Self.blockSize))
            state = .data(remaining: entry.size, padding: remainder == 0 ? 0 : Self.blockSize - remainder)
        } else {
            try onEntryEnd()
        }
        return count
    }

    static func parse(_ header: UnsafeRawBufferPointer) throws -> Entry {
        try verifyChecksum(header)
        let isPOSIX = try headerIsPOSIX(header)
        let name = try entryName(header, isPOSIX: isPOSIX)
        let kind = try entryKind(header, name: name)
        let components = try LocalModelArchivePath.components(of: name)
        let size = try octal(header, offset: 124, length: 12)
        guard kind == .file || size == 0 else { throw LocalModelArchiveError.corruptHeader("directory size") }
        guard string(header, offset: 157, length: 100).isEmpty else {
            throw LocalModelArchiveError.unsupportedEntry(name, "link target")
        }
        return Entry(kind: kind, components: components, size: size)
    }

    private static func verifyChecksum(_ header: UnsafeRawBufferPointer) throws {
        let stored = try octal(header, offset: 148, length: 8)
        var sum: Int64 = 0
        for (index, byte) in header.enumerated() {
            sum += (148..<156).contains(index) ? 0x20 : Int64(byte)
        }
        guard stored == sum else { throw LocalModelArchiveError.corruptHeader("checksum") }
    }

    private static func headerIsPOSIX(_ header: UnsafeRawBufferPointer) throws -> Bool {
        let magic = Array(header[257..<265])
        if magic == Array("ustar\u{0}00".utf8) { return true }
        if magic == Array("ustar  \u{0}".utf8) { return false }
        throw LocalModelArchiveError.unsupportedFormat("not a POSIX or GNU ustar header")
    }

    private static func entryName(_ header: UnsafeRawBufferPointer, isPOSIX: Bool) throws -> String {
        let name = string(header, offset: 0, length: 100)
        guard isPOSIX else { return name }
        let prefix = string(header, offset: 345, length: 155)
        return prefix.isEmpty ? name : prefix + "/" + name
    }

    private static func entryKind(_ header: UnsafeRawBufferPointer, name: String) throws -> Entry.Kind {
        switch header[156] {
        case 0x30, 0x00: return .file
        case 0x35: return .directory
        case 0x31: throw LocalModelArchiveError.unsupportedEntry(name, "hard link")
        case 0x32: throw LocalModelArchiveError.unsupportedEntry(name, "symbolic link")
        case 0x33, 0x34: throw LocalModelArchiveError.unsupportedEntry(name, "device")
        case 0x36: throw LocalModelArchiveError.unsupportedEntry(name, "FIFO")
        case 0x78, 0x67: throw LocalModelArchiveError.unsupportedEntry(name, "pax extended header")
        case 0x4c, 0x4b: throw LocalModelArchiveError.unsupportedEntry(name, "GNU long-name record")
        default: throw LocalModelArchiveError.unsupportedEntry(name, "special entry")
        }
    }

    private static func string(_ header: UnsafeRawBufferPointer, offset: Int, length: Int) -> String {
        let field = header[offset..<(offset + length)]
        let end = field.firstIndex(of: 0) ?? field.endIndex
        return String(decoding: field[field.startIndex..<end], as: UTF8.self)
    }

    /// Octal number, optionally space-padded and NUL- or space-terminated.
    /// Base-256 (binary) numbers are refused.
    static func octal(_ header: UnsafeRawBufferPointer, offset: Int, length: Int) throws -> Int64 {
        var value: Int64 = 0
        var digits = 0
        var index = offset
        let end = offset + length
        guard header[offset] & 0x80 == 0 else { throw LocalModelArchiveError.unsupportedFormat("binary number") }
        while index < end, header[index] == 0x20 { index += 1 }
        while index < end, (0x30...0x37).contains(header[index]) {
            value = value * 8 + Int64(header[index] - 0x30)
            digits += 1
            guard digits <= 11 else { throw LocalModelArchiveError.corruptHeader("number") }
            index += 1
        }
        guard digits > 0 else { throw LocalModelArchiveError.corruptHeader("number") }
        while index < end {
            guard header[index] == 0x20 || header[index] == 0 else { throw LocalModelArchiveError.corruptHeader("number") }
            index += 1
        }
        return value
    }
}
