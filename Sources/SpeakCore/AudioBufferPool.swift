import Foundation
import os.log

/// A thread-safe pool of reusable `Data` buffers for audio streaming.
/// Reduces memory allocations during real-time audio processing.
public final class AudioBufferPool: @unchecked Sendable {
    private var unfairLock = os_unfair_lock()
    private var availableBuffers: [Data]
    private var bufferSize: Int
    private let initialPoolSize: Int
    private let logger = Logger(subsystem: "com.speak.app", category: "AudioBufferPool")

    // Metrics
    public private(set) var poolHits: Int = 0
    public private(set) var poolMisses: Int = 0
    public private(set) var growthCount: Int = 0

    /// Creates a new buffer pool.
    /// - Parameters:
    ///   - poolSize: Initial number of buffers to pre-allocate. Defaults to 10.
    ///   - bufferSize: Capacity of each buffer in bytes. Defaults to 4096.
    public init(poolSize: Int = 10, bufferSize: Int = 4096) {
        self.initialPoolSize = poolSize
        self.bufferSize = bufferSize
        self.availableBuffers = []
        self.availableBuffers.reserveCapacity(poolSize)

        for _ in 0..<poolSize {
            var buffer = Data()
            buffer.reserveCapacity(bufferSize)
            availableBuffers.append(buffer)
        }

        logger.info("AudioBufferPool initialized with \(poolSize) buffers of \(bufferSize) bytes each")
    }

    /// Checks out a buffer from the pool. If the pool is exhausted, a new buffer is created.
    /// - Returns: A `Data` buffer ready for use.
    public func checkout() -> Data {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        if let buffer = availableBuffers.popLast() {
            poolHits += 1
            return buffer
        }

        // Pool exhausted - grow by creating a new buffer
        poolMisses += 1
        growthCount += 1
        logger.warning(
            "AudioBufferPool exhausted, growing pool. Hits: \(self.poolHits), Misses: \(self.poolMisses), Growth: \(self.growthCount)"
        )

        var newBuffer = Data()
        newBuffer.reserveCapacity(bufferSize)
        return newBuffer
    }

    /// Returns a buffer to the pool after use.
    /// The buffer contents are cleared for security before being returned to the pool.
    /// - Parameter buffer: The buffer to return.
    public func returnBuffer(_ buffer: inout Data) {
        // Clear buffer contents for security
        buffer.resetBytes(in: 0..<buffer.count)
        buffer.removeAll(keepingCapacity: true)

        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        availableBuffers.append(buffer)
    }

    /// Returns the current metrics as a dictionary for logging.
    public func metricsSnapshot() -> [String: Int] {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        return [
            "poolHits": poolHits,
            "poolMisses": poolMisses,
            "growthCount": growthCount,
            "availableBuffers": availableBuffers.count,
            "initialPoolSize": initialPoolSize
        ]
    }

    /// Resets metrics counters (useful for testing or periodic logging).
    public func resetMetrics() {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        poolHits = 0
        poolMisses = 0
        growthCount = 0
    }

    /// Logs current pool metrics.
    public func logMetrics() {
        let metrics = metricsSnapshot()
        logger.info(
            "AudioBufferPool metrics - Hits: \(metrics["poolHits"] ?? 0), Misses: \(metrics["poolMisses"] ?? 0), Growth: \(metrics["growthCount"] ?? 0), Available: \(metrics["availableBuffers"] ?? 0)"
        )
    }
}
