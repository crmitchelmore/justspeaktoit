import Foundation
import SpeakCore

/// The native per-attempt ledger, not the Mac successful-result usage format.
public struct DesktopVoiceUsageLedger: Sendable {
    public static let maximumBytes = 2 * 1_024 * 1_024

    public let originalBytes: Data
    public let records: [VoiceSynthesisUsage.Record]
    private let elements: [Data]

    public init(validating bytes: Data) throws {
        try Task.checkCancellation()
        guard bytes.count <= Self.maximumBytes else { throw Failure.tooLarge }
        // Raw slices use the native writer's UTF-8 encoding, never transcoded UTF-16/32.
        guard !bytes.contains(0), String(data: bytes, encoding: .utf8) != nil else { throw Failure.invalid }
        let decoded: [VoiceSynthesisUsage.Record]
        do { decoded = try JSONDecoder().decode([VoiceSynthesisUsage.Record].self, from: bytes) } catch {
            throw Failure.invalid
        }
        try Task.checkCancellation()
        guard decoded.count <= VoiceUsagePolicy.maximumRetainedRequests,
              decoded.allSatisfy(Self.accepts) else { throw Failure.invalid }
        self.originalBytes = bytes
        self.records = decoded
        self.elements = try Self.rawElements(bytes, count: decoded.count)
    }

    /// Only new observations are encoded. Accepted prior elements retain their
    /// unknown members, number spelling and member order byte for byte.
    public func appending(_ observations: [VoiceSynthesisUsage.Record]) throws -> Data {
        var entries = Array(zip(records, elements))
        var seen: [UUID: VoiceSynthesisUsage.Record] = [:]
        for record in records {
            if let previous = seen.updateValue(record, forKey: record.id), previous != record {
                throw Failure.conflictingIdentity
            }
        }
        for record in observations {
            try Task.checkCancellation()
            guard Self.accepts(record) else { throw Failure.invalid }
            if let previous = seen[record.id] {
                guard previous == record else { throw Failure.conflictingIdentity }
                continue
            }
            seen[record.id] = record
            entries.append((record, try JSONEncoder().encode(record)))
        }
        let retained = entries.suffix(VoiceUsagePolicy.maximumRetainedRequests)
        var bytes = Data([0x5B])
        for (index, entry) in retained.enumerated() {
            try Task.checkCancellation()
            if index > 0 { bytes.append(0x2C) }
            guard entry.1.count <= Self.maximumBytes - bytes.count - 1 else { throw Failure.tooLarge }
            bytes.append(entry.1)
        }
        bytes.append(0x5D)
        return bytes
    }

    private static func accepts(_ record: VoiceSynthesisUsage.Record) -> Bool {
        record.inputCharacters >= 0 && record.inputCharacters <= 100_000
            && (record.audioDuration.map { $0.isFinite && $0 >= 0 } ?? true)
            && (record.reportedInputTokens.map { $0 >= 0 } ?? true)
            && (record.estimatedInputCostUSD.map { $0 >= 0 } ?? true)
            && (record.estimatedAudioCostUSD.map { $0 >= 0 } ?? true)
    }

    private static func rawElements(_ data: Data, count: Int) throws -> [Data] {
        let bytes = [UInt8](data)
        var elements: [Data] = []
        var depth = 0
        var quoted = false
        var escaped = false
        var start: Int?
        for (index, byte) in bytes.enumerated() {
            if index.isMultiple(of: 65_536) { try Task.checkCancellation() }
            if scanString(byte, quoted: &quoted, escaped: &escaped) { continue }
            if byte == 0x7B || byte == 0x5B {
                if depth == 1 { start = index }
                depth += 1
            } else if byte == 0x7D || byte == 0x5D {
                depth -= 1
                if depth == 1, let lower = start {
                    elements.append(Data(bytes[lower...index]))
                    start = nil
                }
            }
        }
        guard elements.count == count else { throw Failure.invalid }
        return elements
    }

    private static func scanString(_ byte: UInt8, quoted: inout Bool, escaped: inout Bool) -> Bool {
        if quoted {
            if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 {
                quoted = false
            }
            return true
        }
        guard byte == 0x22 else { return false }
        quoted = true
        return true
    }

    public enum Failure: LocalizedError, Equatable {
        case tooLarge, invalid, conflictingIdentity

        public var errorDescription: String? {
            switch self {
            case .tooLarge: "The Voice usage ledger exceeds its size limit."
            case .invalid: "The Voice usage ledger contains invalid or unsupported observations."
            case .conflictingIdentity: "Voice usage observations disagree for the same request identifier."
            }
        }
    }
}
