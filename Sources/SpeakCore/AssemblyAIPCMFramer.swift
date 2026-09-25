import Foundation

/// Buffers less than 100 ms between calls. The client admits PCM into its total
/// byte budget before framing. Final nonempty tails are padded to the API's
/// 50 ms minimum; an empty recording never creates an artificial audio frame.
struct AssemblyAIPCMFramer {
    let minimumBytes: Int
    let preferredBytes: Int
    private var pending = Data()
    var bufferedByteCount: Int { pending.count }

    init(sampleRate: Int) {
        minimumBytes = max(1, (sampleRate + 19) / 20) * 2
        preferredBytes = max(minimumBytes, max(1, sampleRate / 10) * 2)
    }

    mutating func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        if pending.isEmpty, data.count == preferredBytes { return [data] }
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
        if pending.count < minimumBytes { pending.append(Data(repeating: 0, count: minimumBytes - pending.count)) }
        let result = pending
        pending = Data()
        return result
    }

    mutating func reset() { pending = Data() }
}
