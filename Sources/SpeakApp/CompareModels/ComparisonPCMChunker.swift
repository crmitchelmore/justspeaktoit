import Foundation

/// A bounded 100 ms packet stream, with at most 50 ms of padding at the tail.
/// Used on the audio-processing queue; the retained capture is never padded.
final class ComparisonPCMChunker {
    private var pending = Data()
    private let packetBytes: Int
    private let minimumBytes: Int

    init(sampleRate: Int) {
        packetBytes = max(2, sampleRate / 10 * 2)
        minimumBytes = max(2, sampleRate / 20 * 2)
    }

    func append(_ data: Data, send: (Data) -> Void) {
        pending.append(data)
        while pending.count >= packetBytes {
            send(Data(pending.prefix(packetBytes)))
            pending.removeFirst(packetBytes)
        }
    }

    func finish(send: (Data) -> Void) {
        guard !pending.isEmpty else { return }
        if pending.count < minimumBytes {
            pending.append(Data(repeating: 0, count: minimumBytes - pending.count))
        }
        send(pending)
        pending = Data()
    }
}
