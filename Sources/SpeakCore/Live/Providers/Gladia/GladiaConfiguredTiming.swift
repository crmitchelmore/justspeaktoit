import Foundation

/// Only the new required-options construction uses staged shutdown.
/// Legacy constructors retain their raw framing and single whole deadline.
enum GladiaLiveMode: Sendable {
    case legacy
    case configured(GladiaConfiguredTiming?)

    var timing: GladiaConfiguredTiming? {
        if case .configured(let timing) = self { return timing }
        return nil
    }

    var isConfigured: Bool {
        if case .configured = self { return true }
        return false
    }
}

struct GladiaTimingConfigurationError: LocalizedError, Equatable, Sendable {
    var errorDescription: String? {
        "Gladia live stop timing cannot be scheduled safely. Check the live transcription stop settings."
    }
}

struct GladiaConfiguredTiming: Sendable {
    let grace: TimeInterval
    let finalWindow: TimeInterval
    let total: TimeInterval
    static let drain: TimeInterval = 1.5
    static let control: TimeInterval = 1.5

    init?(options: LiveClientOptions) {
        grace = options.stopGracePeriod
        finalWindow = options.postStopFinalizeBudget ?? GladiaLive.finalEventWindow
        total = Self.drain + grace + Self.control + finalWindow
        guard isSchedulable() else { return nil }
    }

    /// Rechecked at each start, since a client may outlive the clock headroom
    /// that was available when it was constructed. All checks share one now.
    func isSchedulable(now: DispatchTime = .now()) -> Bool {
        [Self.drain, grace, Self.control, finalWindow, total, GladiaLiveClient.readyDeadline]
            .allSatisfy { Self.deadline(after: $0, now: now) != nil }
    }

    /// Dispatch's delta is signed nanoseconds, while its time encoding is
    /// opaque. Check conversion before constructing a typed deadline, then
    /// refuse saturation rather than turning a bounded wait into infinity.
    static func deadline(after seconds: TimeInterval, now: DispatchTime = .now()) -> DispatchTime? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let scaled = (seconds * 1_000_000_000).rounded(.up)
        guard scaled.isFinite, let delta = Int64(exactly: scaled), let nanoseconds = Int(exactly: delta),
              now != .distantFuture else { return nil }
        let deadline = now + .nanoseconds(nanoseconds)
        guard deadline != .distantFuture, seconds == 0 || deadline > now else { return nil }
        return deadline
    }
}
