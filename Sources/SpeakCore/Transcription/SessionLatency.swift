import Foundation

/// Per-session latency figures measured across one dictation session, from the
/// trigger (hotkey press / UI button) through audio-capture start, the first
/// streamed partial, the first character reaching the target app, the stop
/// gesture, and the final insert completing.
///
/// Intervals are persisted as whole milliseconds rather than timestamps:
/// history persistence encodes dates as whole-second ISO-8601, which would
/// silently destroy sub-second latency data. Every interval is optional —
/// batch sessions have no partials, clipboard-only sessions may never insert
/// live, and failed sessions stop part-way.
///
/// Stored on `HistoryItem` as an additive optional field — old history items
/// decode with `latency == nil`.
public struct SessionLatencyMetrics: Codable, Hashable, Sendable {
    /// Cold start: trigger (hotkey press / UI button) → audio capture running.
    public let captureStartMs: Int?
    /// Capture running → first non-empty live partial received.
    public let firstPartialMs: Int?
    /// Capture running → first character visible in the target app.
    public let firstInsertMs: Int?
    /// Stop pressed → final insert complete.
    public let stopToFinalMs: Int?

    public init(
        captureStartMs: Int? = nil,
        firstPartialMs: Int? = nil,
        firstInsertMs: Int? = nil,
        stopToFinalMs: Int? = nil
    ) {
        self.captureStartMs = captureStartMs
        self.firstPartialMs = firstPartialMs
        self.firstInsertMs = firstInsertMs
        self.stopToFinalMs = stopToFinalMs
    }

    /// Builds the metrics from raw wall-clock checkpoints. Intervals whose
    /// endpoints are missing, or which are negative (clock skew), become `nil`.
    public init(
        hotKeyPressedAt: Date?,
        captureStartedAt: Date?,
        firstPartialAt: Date?,
        firstInsertAt: Date?,
        stopPressedAt: Date?,
        finalInsertAt: Date?
    ) {
        self.init(
            captureStartMs: Self.milliseconds(from: hotKeyPressedAt, to: captureStartedAt),
            firstPartialMs: Self.milliseconds(from: captureStartedAt, to: firstPartialAt),
            firstInsertMs: Self.milliseconds(from: captureStartedAt, to: firstInsertAt),
            stopToFinalMs: Self.milliseconds(from: stopPressedAt, to: finalInsertAt)
        )
    }

    /// True when at least one interval is measurable.
    public var hasAnyInterval: Bool {
        self.captureStartMs != nil || self.firstPartialMs != nil
            || self.firstInsertMs != nil || self.stopToFinalMs != nil
    }

    /// Whole milliseconds between two optional instants; `nil` when either
    /// endpoint is missing or the interval is negative (clock skew).
    public static func milliseconds(from start: Date?, to end: Date?) -> Int? {
        guard let start, let end else { return nil }
        let interval = end.timeIntervalSince(start)
        guard interval >= 0 else { return nil }
        return Int((interval * 1000).rounded())
    }

    /// Compact human-readable duration: "320 ms" below a second, "1.4 s" above.
    public static func formattedMilliseconds(_ milliseconds: Int) -> String {
        guard milliseconds >= 1000 else { return "\(milliseconds) ms" }
        return String(format: "%.1f s", Double(milliseconds) / 1000)
    }
}

/// Percentile math for latency aggregation (nearest-rank method).
public enum LatencyPercentiles {
    /// Nearest-rank percentile of `values`. Returns `nil` for an empty input.
    /// `percentile` is clamped to 0...100; 0 returns the minimum, 100 the maximum.
    public static func percentile(_ percentile: Double, of values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(max(percentile, 0), 100)
        guard clamped > 0 else { return sorted[0] }
        let rank = Int((clamped / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    public static func p50(of values: [Int]) -> Int? {
        self.percentile(50, of: values)
    }

    public static func p95(of values: [Int]) -> Int? {
        self.percentile(95, of: values)
    }
}
