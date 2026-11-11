import Foundation

/// Frames converted PCM16 into fixed upload chunks for a live socket that
/// rejects short frames. Full `preferredChunkBytes` chunks leave as soon as
/// they exist; the final remainder is zero-padded up to `minimumChunkBytes`.
/// Not thread-safe: the owning audio queue serialises every call.
struct LivePCMChunkFramer {
    let minimumChunkBytes: Int
    let preferredChunkBytes: Int
    private var pending = Data()

    /// 50 ms minimum and 100 ms preferred chunks of mono PCM16 at `sampleRate`.
    init(sampleRate: Int) {
        minimumChunkBytes = (sampleRate / 1000) * 50 * 2
        preferredChunkBytes = (sampleRate / 1000) * 100 * 2
    }

    var isEmpty: Bool { pending.isEmpty }

    mutating func append(_ pcm: Data) {
        pending.append(pcm)
    }

    /// Removes and returns every complete preferred-size chunk, in order.
    mutating func takeFullChunks() -> [Data] {
        var chunks: [Data] = []
        var offset = 0
        while pending.count - offset >= preferredChunkBytes {
            chunks.append(pending.subdata(in: offset..<(offset + preferredChunkBytes)))
            offset += preferredChunkBytes
        }
        if offset > 0 {
            pending = Data(pending.dropFirst(offset))
        }
        return chunks
    }

    /// Removes and returns everything left: full chunks, then the remainder
    /// zero-padded to the minimum frame size.
    mutating func takeAll() -> [Data] {
        var chunks = takeFullChunks()
        guard !pending.isEmpty else { return chunks }
        if pending.count < minimumChunkBytes {
            pending.append(contentsOf: repeatElement(0, count: minimumChunkBytes - pending.count))
        }
        chunks.append(pending)
        pending.removeAll(keepingCapacity: false)
        return chunks
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: false)
    }
}
