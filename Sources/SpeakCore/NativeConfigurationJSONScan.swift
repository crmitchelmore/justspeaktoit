import Foundation

/// Bounds parser work and rejects duplicate JSON members before Foundation can collapse them.
enum NativeConfigurationJSONScan {
    static func validate(_ data: Data, checkCancellation: () throws -> Void) throws {
        try checkCancellation()
        guard UInt64(data.count) <= DesktopNativeConfigurationArchiveCodec.maximumEncodedBytes else { throw invalid() }
        let bytes = Array(data)
        var state = NativeConfigurationJSONState()
        for index in bytes.indices {
            if index % 4096 == 0 { try checkCancellation() }
            try state.admit(bytes, at: index, checkCancellation: checkCancellation)
        }
        try checkCancellation()
        guard !state.inString, state.frames.isEmpty else { throw invalid() }
    }

    fileprivate static func invalid() -> DataMigrationError {
        .invalid("Malformed or unbounded native configuration JSON.")
    }
}

private struct NativeConfigurationJSONFrame {
    let opener: UInt8
    var keys = Set<String>()
}

private struct NativeConfigurationJSONState {
    var frames: [NativeConfigurationJSONFrame] = []
    var inString = false
    private var escaped = false
    private var stringStart = 0
    private var tokens = 0
    private var records = 1

    mutating func admit(_ bytes: [UInt8], at index: Int, checkCancellation: () throws -> Void) throws {
        let byte = bytes[index]
        if inString {
            try admitStringByte(bytes, at: index, checkCancellation: checkCancellation)
            return
        }
        switch byte {
        case 34:
            inString = true
            stringStart = index
            tokens += 1
        case 123, 91:
            frames.append(.init(opener: byte))
            tokens += 1
            guard frames.count <= 8 else { throw NativeConfigurationJSONScan.invalid() }
        case 125, 93:
            guard let frame = frames.popLast(), frame.opener == (byte == 125 ? 123 : 91) else {
                throw NativeConfigurationJSONScan.invalid()
            }
        case 44:
            tokens += 1
            if frames.count == 1, frames.first?.opener == 91 { records += 1 }
        default:
            break
        }
        guard tokens <= 4096, records <= DesktopNativeConfigurationArchiveCodec.maximumRecords else {
            throw NativeConfigurationJSONScan.invalid()
        }
    }

    private mutating func admitStringByte(
        _ bytes: [UInt8], at index: Int, checkCancellation: () throws -> Void
    ) throws {
        let byte = bytes[index]
        if escaped { escaped = false; return }
        if byte == 92 { escaped = true; return }
        if byte == 34 {
            inString = false
            try admitKey(bytes, through: index, checkCancellation: checkCancellation)
        }
    }

    private mutating func admitKey(
        _ bytes: [UInt8], through end: Int, checkCancellation: () throws -> Void
    ) throws {
        var next = end + 1
        while next < bytes.count, [9, 10, 13, 32].contains(bytes[next]) {
            if next % 4096 == 0 { try checkCancellation() }
            next += 1
        }
        guard next < bytes.count, bytes[next] == 58 else { return }
        guard frames.last?.opener == 123, end - stringStart <= 512 else {
            throw NativeConfigurationJSONScan.invalid()
        }
        let key = try JSONDecoder().decode(String.self, from: Data(bytes[stringStart...end]))
        guard frames[frames.count - 1].keys.count < 32,
              frames[frames.count - 1].keys.insert(key).inserted else {
            throw NativeConfigurationJSONScan.invalid()
        }
    }
}
