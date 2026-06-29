import Foundation
import os.log

/// A thread-safe pool of reusable `Data` buffers for audio streaming.
/// Reduces memory allocations during real-time audio processing.
/// Uses os_unfair_lock for minimal overhead on the audio hot path.
final class AudioBufferPool: @unchecked Sendable {
    private var unfairLock = os_unfair_lock()
    private var availableBuffers: [Data]
    private var bufferSize: Int
    private let initialPoolSize: Int
    private let logger = Logger(subsystem: "com.speak.app", category: "AudioBufferPool")

    // Metrics
    private var _poolHits: Int = 0
    private var _poolMisses: Int = 0
    private var _growthCount: Int = 0

    var poolHits: Int {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        return _poolHits
    }

    var poolMisses: Int {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        return _poolMisses
    }

    var growthCount: Int {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        return _growthCount
    }

    /// Creates a new buffer pool.
    /// - Parameters:
    ///   - poolSize: Initial number of buffers to pre-allocate. Defaults to 10.
    ///   - bufferSize: Capacity of each buffer in bytes. Defaults to 4096.
    init(poolSize: Int = 10, bufferSize: Int = 4096) {
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
    func checkout() -> Data {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        if let buffer = availableBuffers.popLast() {
            _poolHits += 1
            return buffer
        }

        // Pool exhausted - grow by creating a new buffer
        _poolMisses += 1
        _growthCount += 1
        logger.warning(
            "Pool exhausted. Hits: \(self._poolHits), Misses: \(self._poolMisses), Growth: \(self._growthCount)"
        )

        var newBuffer = Data()
        newBuffer.reserveCapacity(bufferSize)
        return newBuffer
    }

    /// Returns a buffer to the pool after use.
    /// The buffer contents are cleared for security before being returned to the pool.
    /// - Parameter buffer: The buffer to return.
    func returnBuffer(_ buffer: inout Data) {
        // Clear buffer contents for security
        buffer.resetBytes(in: 0..<buffer.count)
        buffer.removeAll(keepingCapacity: true)

        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        availableBuffers.append(buffer)
    }

    /// Returns the current metrics as a dictionary for logging.
    func metricsSnapshot() -> [String: Int] {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        return [
            "poolHits": _poolHits,
            "poolMisses": _poolMisses,
            "growthCount": _growthCount,
            "availableBuffers": availableBuffers.count,
            "initialPoolSize": initialPoolSize
        ]
    }

    /// Resets metrics counters (useful for testing or periodic logging).
    func resetMetrics() {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        _poolHits = 0
        _poolMisses = 0
        _growthCount = 0
    }

    /// Logs current pool metrics.
    func logMetrics() {
        let metrics = metricsSnapshot()
        let hits = metrics["poolHits"] ?? 0
        let misses = metrics["poolMisses"] ?? 0
        let growth = metrics["growthCount"] ?? 0
        let available = metrics["availableBuffers"] ?? 0

        logger.info(
            "Pool metrics. Hits: \(hits), Misses: \(misses), Growth: \(growth), Available: \(available)"
        )
    }
}
