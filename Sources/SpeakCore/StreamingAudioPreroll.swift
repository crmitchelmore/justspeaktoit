import Foundation

/// Bounded hold-and-replay buffer for PCM captured before a streaming
/// provider's transport is ready to carry it (issue #641).
///
/// Live capture starts as soon as the audio engine is running, but a WebSocket
/// handshake takes as long as it takes. Providers that simply dropped audio
/// while `URLSessionWebSocketTask.state != .running` lost the user's opening
/// words. Chunks parked here are replayed, in capture order, on the first send
/// that finds a live transport.
///
/// The budget is expressed in seconds of PCM so it is meaningful regardless of
/// sample rate; when it is exceeded the *oldest* chunks are dropped, keeping the
/// audio nearest the connection contiguous. Five seconds matches the bound the
/// Gladia client already uses for the same problem.
public final class StreamingAudioPreroll: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public let chunkCount: Int
        public let byteCount: Int
        /// Chunks evicted because the budget was exceeded. A non-zero value in
        /// diagnostics means the transport took longer than the budget to come
        /// up, and some leading audio really was lost.
        public let droppedChunkCount: Int

        public init(chunkCount: Int, byteCount: Int, droppedChunkCount: Int) {
            self.chunkCount = chunkCount
            self.byteCount = byteCount
            self.droppedChunkCount = droppedChunkCount
        }
    }

    /// Seconds of leading audio held while a transport connects.
    public static let defaultBudgetSeconds: Double = 5

    private let maximumByteCount: Int
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var bufferedByteCount = 0
    private var droppedChunkCount = 0

    /// - Parameters:
    ///   - sampleRate: Capture sample rate in Hz.
    ///   - seconds: Budget in seconds of audio.
    ///   - bytesPerFrame: 2 for the PCM16 mono every streaming provider here uses.
    public init(sampleRate: Int, seconds: Double = StreamingAudioPreroll.defaultBudgetSeconds, bytesPerFrame: Int = 2) {
        let rate = max(sampleRate, 1)
        let budget = max(seconds, 0)
        self.maximumByteCount = max(Int(Double(rate * max(bytesPerFrame, 1)) * budget), 0)
    }

    public var isEmpty: Bool {
        self.lock.withLock { self.chunks.isEmpty }
    }

    public var snapshot: Snapshot {
        self.lock.withLock {
            Snapshot(
                chunkCount: self.chunks.count,
                byteCount: self.bufferedByteCount,
                droppedChunkCount: self.droppedChunkCount
            )
        }
    }

    /// Parks a chunk captured before the transport was ready.
    public func append(_ chunk: Data) {
        guard !chunk.isEmpty, self.maximumByteCount > 0 else { return }
        self.lock.withLock {
            self.chunks.append(chunk)
            self.bufferedByteCount += chunk.count
            while self.bufferedByteCount > self.maximumByteCount, !self.chunks.isEmpty {
                self.bufferedByteCount -= self.chunks.removeFirst().count
                self.droppedChunkCount += 1
            }
        }
    }

    /// Returns everything held, in capture order, and empties the buffer.
    public func drain() -> [Data] {
        self.lock.withLock {
            let held = self.chunks
            self.chunks.removeAll(keepingCapacity: true)
            self.bufferedByteCount = 0
            return held
        }
    }

    /// Clears buffered audio and counters, for session start/stop.
    public func reset() {
        self.lock.withLock {
            self.chunks.removeAll(keepingCapacity: true)
            self.bufferedByteCount = 0
            self.droppedChunkCount = 0
        }
    }
}
