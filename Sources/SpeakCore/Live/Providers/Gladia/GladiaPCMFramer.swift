import Foundation

/// Used only after the client validates the supported sample rate. Whole
/// samples are admitted into the run's total bound before this copies them.
struct GladiaPCMFramer {
    let preferredBytes: Int
    let minimumBytes: Int
    private var pending = Data()
    var bufferedByteCount: Int { pending.count }
    var finalPaddingBytes: Int { pending.isEmpty ? 0 : max(0, minimumBytes - pending.count) }

    init(sampleRate: Int) {
        preferredBytes = sampleRate * 2 / 10
        minimumBytes = sampleRate * 2 / 20
    }

    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var frames: [Data] = []
        var offset = 0
        while pending.count - offset >= preferredBytes {
            frames.append(pending.subdata(in: offset..<(offset + preferredBytes)))
            offset += preferredBytes
        }
        if offset > 0 { pending = Data(pending.dropFirst(offset)) }
        return frames
    }

    mutating func finish() -> Data? {
        guard !pending.isEmpty else { return nil }
        pending.append(Data(repeating: 0, count: finalPaddingBytes))
        defer { pending = Data() }
        return pending
    }
}
