import Foundation

/// The Mac's normalized meter scale and user-configurable silence hold.
public enum DictationSilencePolicy {
    public static let defaultThreshold = 0.05
    public static let thresholdRange: ClosedRange<Double> = 0.01...0.2
    public static let durationRange: ClosedRange<Double> = 0.5...5
    public static let defaultDuration = HandsFreeDictationPolicy.defaultSilenceHoldSeconds

    public static func normalizedLevel(_ samples: UnsafeBufferPointer<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var squares = 0.0
        var peak = 0.0
        for sample in samples {
            let amplitude = abs(Double(sample)) / 32768
            squares += amplitude * amplitude
            peak = max(peak, amplitude)
        }
        guard peak > 0 else { return 0 }
        let averageDB = 20 * log10(sqrt(squares / Double(samples.count)))
        let peakDB = 20 * log10(peak)
        return max(0, min(1, (0.7 * averageDB + 0.3 * peakDB + 60) / 60))
    }
}

/// Manual auto-stop includes initial quiet, unlike hands-free utterance edges.
public struct DictationSilenceMonitor: Sendable {
    private var silentSince: Double?
    private var stopped = false
    public let threshold: Double
    public let duration: Double

    public init(threshold: Double, duration: Double) {
        self.threshold = threshold
        self.duration = duration
    }

    public mutating func observe(level: Double, atSeconds seconds: Double) -> Bool {
        guard !stopped, level.isFinite, seconds.isFinite else { return false }
        guard level < threshold else { silentSince = nil; return false }
        guard let since = silentSince, seconds >= since else {
            silentSince = seconds
            return false
        }
        guard seconds - since >= duration else { return false }
        stopped = true
        return true
    }
}
