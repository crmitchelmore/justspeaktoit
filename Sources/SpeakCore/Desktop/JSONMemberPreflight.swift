import Foundation

/// Extracted from 86a0568b NativeConfigurationJSONScan, blob 6051688578a75c72b6b9144f46cfc62cf16b6fe9.
/// Bounds member scanning before Foundation decoding; grammar/schema validation remains caller-owned.
enum JSONMemberPreflight {
    struct Limits {
        let maximumBytes: UInt64
        let maximumDepth: Int
        let maximumTokens: Int
        let maximumRootRecords: Int
        let maximumObjectKeys: Int
        /// Closing quote index minus opening quote index, not decoded character count.
        let maximumEncodedKeySpan: Int
        let cancellationStride: Int
    }

    static func validate(
        _ data: Data, limits: Limits, checkCancellation: () throws -> Void, invalid: @escaping () -> Error
    ) throws {
        try checkCancellation()
        guard limits.maximumDepth >= 0, limits.maximumTokens >= 0, limits.maximumRootRecords >= 0,
              limits.maximumObjectKeys >= 0, limits.maximumEncodedKeySpan >= 0,
              limits.cancellationStride > 0, UInt64(data.count) <= limits.maximumBytes else { throw invalid() }
        let bytes = Array(data)
        var state = JSONMemberPreflightState(limits: limits, invalid: invalid)
        for index in bytes.indices {
            if index % limits.cancellationStride == 0 { try checkCancellation() }
            try state.admit(bytes, at: index, checkCancellation: checkCancellation)
        }
        try checkCancellation()
        guard !state.inString, state.frames.isEmpty else { throw invalid() }
    }
}

private struct JSONMemberPreflightFrame {
    let opener: UInt8
    var keys = Set<String>()
}

private struct JSONMemberPreflightState {
    let limits: JSONMemberPreflight.Limits
    let invalid: () -> Error
    var frames: [JSONMemberPreflightFrame] = []
    var inString = false
    private var escaped = false
    private var stringStart = 0
    private var tokens = 0
    private var records = 1

    init(limits: JSONMemberPreflight.Limits, invalid: @escaping () -> Error) {
        self.limits = limits
        self.invalid = invalid
    }

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
            guard frames.count <= limits.maximumDepth else { throw invalid() }
        case 125, 93:
            guard let frame = frames.popLast(), frame.opener == (byte == 125 ? 123 : 91) else {
                throw invalid()
            }
        case 44:
            tokens += 1
            if frames.count == 1, frames.first?.opener == 91 { records += 1 }
        default:
            break
        }
        guard tokens <= limits.maximumTokens, records <= limits.maximumRootRecords else { throw invalid() }
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
            if next % limits.cancellationStride == 0 { try checkCancellation() }
            next += 1
        }
        guard next < bytes.count, bytes[next] == 58 else { return }
        guard frames.last?.opener == 123, end - stringStart <= limits.maximumEncodedKeySpan else { throw invalid() }
        let key = try JSONDecoder().decode(String.self, from: Data(bytes[stringStart...end]))
        guard frames[frames.count - 1].keys.count < limits.maximumObjectKeys,
              frames[frames.count - 1].keys.insert(key).inserted else { throw invalid() }
    }
}
