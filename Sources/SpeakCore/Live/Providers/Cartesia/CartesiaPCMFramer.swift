import Foundation

/// Repacks capture chunks into 100 ms PCM16 frames for the Cartesia stream.
/// A chunk need not hold whole samples: bytes carry over to the next chunk.
/// The final tail is padded to the 50 ms minimum and to a whole sample; an
/// empty recording never creates an artificial audio frame.
struct CartesiaPCMFramer {
    private let preferredBytes: Int
    private let minimumBytes: Int
    private var buffered = Data()
    var bufferedByteCount: Int { buffered.count }

    init(sampleRate: Int) {
        preferredBytes = max(2, sampleRate * 2 / 10)
        minimumBytes = max(2, sampleRate * 2 / 20)
    }

    mutating func append(_ data: Data) -> [Data] {
        buffered.append(data)
        var frames: [Data] = []
        while buffered.count >= preferredBytes {
            frames.append(Data(buffered.prefix(preferredBytes)))
            buffered.removeFirst(preferredBytes)
        }
        return frames
    }

    mutating func finish() -> Data? {
        guard !buffered.isEmpty else { return nil }
        if buffered.count < minimumBytes {
            buffered.append(Data(repeating: 0, count: minimumBytes - buffered.count))
        }
        if !buffered.count.isMultiple(of: 2) { buffered.append(0) }
        defer { buffered.removeAll(keepingCapacity: false) }
        return buffered
    }
}
