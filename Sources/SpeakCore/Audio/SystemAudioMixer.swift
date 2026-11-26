import Foundation

/// Combines mono Float32 PCM streams from system audio and microphone capture
/// without blocking either audio callback when the other side is silent or
/// drifts in clock rate.
///
/// Both streams are assumed to be resampled to `sampleRate` mono Float32 before
/// pushing. In `.system` mode samples pass through immediately; in `.both` mode
/// overlapping samples are summed with soft clipping (`[-1, 1]`), and if one
/// stream leads the other by more than `maxLagMilliseconds` the excess is
/// drained so live transcription never stalls during one-sided silence.
public final class SystemAudioMixer: @unchecked Sendable {
    public let source: AudioCaptureSource
    public let sampleRate: Int
    private let maxLagSamples: Int
    private let maxBufferSamples: Int

    private let lock = NSLock()
    private var systemQueue: [Float] = []
    private var micQueue: [Float] = []

    public init(
        source: AudioCaptureSource,
        sampleRate: Int = 48_000,
        maxLagMilliseconds: Int = 200,
        maxBufferMilliseconds: Int = 2_000
    ) {
        self.source = source
        self.sampleRate = max(1, sampleRate)
        let lagFrames = (self.sampleRate * max(1, maxLagMilliseconds)) / 1_000
        let capFrames = max(lagFrames, (self.sampleRate * max(1, maxBufferMilliseconds)) / 1_000)
        self.maxLagSamples = lagFrames
        self.maxBufferSamples = capFrames
    }

    /// Appends system-audio samples and returns any ready mixed samples.
    public func pushSystem(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        self.lock.lock()
        defer { self.lock.unlock() }
        switch self.source {
        case .mic:
            return []
        case .system:
            return samples
        case .both:
            Self.append(samples, to: &self.systemQueue, limit: self.maxBufferSamples)
            return self.drainLocked()
        }
    }

    /// Appends microphone samples and returns any ready mixed samples.
    public func pushMicrophone(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        self.lock.lock()
        defer { self.lock.unlock() }
        switch self.source {
        case .mic:
            return samples
        case .system:
            return []
        case .both:
            Self.append(samples, to: &self.micQueue, limit: self.maxBufferSamples)
            return self.drainLocked()
        }
    }

    /// Emits all remaining queued samples at end of capture.
    public func flush() -> [Float] {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.systemQueue.isEmpty || !self.micQueue.isEmpty else { return [] }
        let overlap = min(self.systemQueue.count, self.micQueue.count)
        let total = max(self.systemQueue.count, self.micQueue.count)
        var output = [Float]()
        output.reserveCapacity(total)
        for index in 0..<overlap {
            output.append(Self.mixSample(self.systemQueue[index], self.micQueue[index]))
        }
        if self.systemQueue.count > overlap {
            output.append(contentsOf: self.systemQueue[overlap...])
        } else if self.micQueue.count > overlap {
            output.append(contentsOf: self.micQueue[overlap...])
        }
        self.systemQueue.removeAll(keepingCapacity: false)
        self.micQueue.removeAll(keepingCapacity: false)
        return output
    }

    /// Discards all buffered samples.
    public func reset() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.systemQueue.removeAll(keepingCapacity: false)
        self.micQueue.removeAll(keepingCapacity: false)
    }

    private func drainLocked() -> [Float] {
        var output: [Float] = []
        let overlap = min(self.systemQueue.count, self.micQueue.count)
        if overlap > 0 {
            output.reserveCapacity(overlap)
            for index in 0..<overlap {
                output.append(Self.mixSample(self.systemQueue[index], self.micQueue[index]))
            }
            self.systemQueue.removeFirst(overlap)
            self.micQueue.removeFirst(overlap)
        }
        if self.systemQueue.count > self.maxLagSamples {
            let drainCount = self.systemQueue.count - self.maxLagSamples
            output.append(contentsOf: self.systemQueue.prefix(drainCount))
            self.systemQueue.removeFirst(drainCount)
        } else if self.micQueue.count > self.maxLagSamples {
            let drainCount = self.micQueue.count - self.maxLagSamples
            output.append(contentsOf: self.micQueue.prefix(drainCount))
            self.micQueue.removeFirst(drainCount)
        }
        return output
    }

    private static func append(_ samples: [Float], to queue: inout [Float], limit: Int) {
        queue.append(contentsOf: samples)
        if queue.count > limit {
            queue.removeFirst(queue.count - limit)
        }
    }

    private static func mixSample(_ first: Float, _ second: Float) -> Float {
        let sum = first + second
        if sum > 1.0 { return 1.0 }
        if sum < -1.0 { return -1.0 }
        return sum
    }
}
