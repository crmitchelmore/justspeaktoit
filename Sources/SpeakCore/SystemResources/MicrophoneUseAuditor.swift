import Foundation

/// What the operating system says about this app's microphone use, compared
/// with the holds components registered.
public enum MicrophoneUseAttribution: Equatable, Sendable {
    /// The OS cannot say (no per-process audio API on this host).
    case unknown
    /// The microphone is closed and nothing claims it.
    case idle
    /// The microphone is open and these holds explain why.
    case attributed([SystemResourceHold])
    /// The microphone is open but no component claims it. This is the
    /// "holding the microphone and nobody knows why" state of issue #1471.
    case unattributed(since: Date)
    /// A hold claims the microphone but the OS reports it closed, e.g. a
    /// paused hands-free detector or a hold whose owner forgot to end it.
    case claimedButClosed([SystemResourceHold])

    public var isUnattributed: Bool {
        if case .unattributed = self { return true }
        return false
    }
}

/// Turns periodic OS samples into a stable attribution.
///
/// Start and stop are not atomic with the OS's view: an engine stops a few
/// milliseconds after its hold ends, and starts a few before its hold begins.
/// A mismatch therefore only counts once it has lasted `grace` seconds, and an
/// unattributed episode is reported once, however long it lasts.
public struct MicrophoneUseAuditor: Sendable {
    public let grace: TimeInterval
    private var mismatchSince: Date?
    /// Which mismatch `mismatchSince` dates: true for an open, unclaimed microphone.
    private var mismatchIsOpen = false
    private var reportedEpisode = false

    public init(grace: TimeInterval = 3) {
        self.grace = grace
    }

    public struct Sample: Equatable, Sendable {
        public let attribution: MicrophoneUseAttribution
        /// True exactly once per unattributed episode, for logging.
        public let shouldReport: Bool
    }

    public mutating func observe(
        osReportsInput: Bool?,
        holds: [SystemResourceHold],
        at now: Date
    ) -> Sample {
        let microphoneHolds = holds.filter { $0.kind == .microphone }
        guard let osReportsInput else {
            reset()
            return Sample(attribution: .unknown, shouldReport: false)
        }
        switch (osReportsInput, microphoneHolds.isEmpty) {
        case (false, true):
            reset()
            return Sample(attribution: .idle, shouldReport: false)
        case (true, false):
            reset()
            return Sample(attribution: .attributed(microphoneHolds), shouldReport: false)
        case (true, true):
            let since = beginMismatch(open: true, at: now)
            guard now.timeIntervalSince(since) >= grace else {
                return Sample(attribution: .idle, shouldReport: false)
            }
            let report = !reportedEpisode
            reportedEpisode = true
            return Sample(attribution: .unattributed(since: since), shouldReport: report)
        case (false, false):
            let since = beginMismatch(open: false, at: now)
            guard now.timeIntervalSince(since) >= grace else {
                return Sample(attribution: .attributed(microphoneHolds), shouldReport: false)
            }
            return Sample(attribution: .claimedButClosed(microphoneHolds), shouldReport: false)
        }
    }

    private mutating func beginMismatch(open: Bool, at now: Date) -> Date {
        if let mismatchSince, mismatchIsOpen == open { return mismatchSince }
        reset()
        mismatchSince = now
        mismatchIsOpen = open
        return now
    }

    private mutating func reset() {
        mismatchSince = nil
        reportedEpisode = false
    }
}

/// Short text for compact surfaces (menu bar, widgets).
public enum SystemResourceSummary {
    public static func headline(for holds: [SystemResourceHold]) -> String {
        let microphone = holds.filter { $0.kind == .microphone }
        if let first = microphone.first {
            let extra = microphone.count > 1 ? " (+\(microphone.count - 1))" : ""
            return "Microphone in use: \(first.title)\(extra)"
        }
        if holds.isEmpty { return "Not holding any system resources" }
        return holds.count == 1 ? "Holding 1 resource" : "Holding \(holds.count) resources"
    }

    /// "for 3 min", "for 12 s", "for 2 h 5 min".
    public static func duration(since: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "for \(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "for \(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "for \(hours) h" : "for \(hours) h \(remainder) min"
    }

    /// One line per hold, for logs and issue reports.
    public static func diagnostics(for holds: [SystemResourceHold], now: Date = Date()) -> String {
        guard !holds.isEmpty else { return "none" }
        return holds.map { hold in
            "\(hold.kind.rawValue): \(hold.title) [\(hold.owner)] \(duration(since: hold.since, now: now))"
        }.joined(separator: "; ")
    }
}
