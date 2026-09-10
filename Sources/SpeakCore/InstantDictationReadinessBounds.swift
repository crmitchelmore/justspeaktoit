// Bounded, self-healing Instant Dictation readiness (issue #995).
//
// Readiness currently has two unbounded ends. It holds the microphone open for
// as long as the app lives, with no window; and the first time iOS takes the
// audio session away — a call, Siri, an AirPods route change — it declares
// itself disconnected and stays that way until the user makes a five-to-seven
// touch round trip through the app.
//
// This file bounds both, and nothing else. It is pure and clock-driven so the
// case that matters — an auto-resume that fails, resumes, and fails again
// forever — is proved by the host test suite rather than by holding a phone
// and answering calls.
import Foundation

// MARK: - Policy

public enum InstantDictationReadinessPolicy {
    /// How long a readiness session may hold the microphone before it expires.
    ///
    /// Four hours is longer than any plausible run of continuous dictation and
    /// far shorter than the "until the process dies" it replaces. Expiry is
    /// deliberately cheap: nothing is being recorded when it fires — see
    /// ``InstantDictationReadinessMonitor``, which never expires a session that
    /// is mid-dictation — so the whole cost is that the microphone stops being
    /// held and the next foreground re-arms it. The user's preference is left
    /// switched on.
    public static let sessionWindowSeconds: TimeInterval = 4 * 60 * 60

    /// How many times readiness will try to restart its own microphone before
    /// it gives up and says so.
    ///
    /// This is the loop bound. A session that dies, resumes, and dies again
    /// gets three attempts and then stops; it does not retry forever, and it
    /// does not retry quickly.
    public static let maximumResumeAttempts = 3

    /// How long readiness must run healthily before the attempt budget is
    /// forgiven.
    ///
    /// Without this, a session that dies every thirty seconds would resume
    /// forever: each death would find a budget reset by the brief success
    /// before it. Two minutes of continuous health is the line between "iOS
    /// interrupted us once" and "this is not going to work".
    public static let resumeBudgetResetSeconds: TimeInterval = 120

    /// Back-off before the nth attempt, 1-based. Rising, so a microphone that
    /// is unavailable because something else holds it is not fought over.
    public static func resumeBackoffSeconds(attempt: Int) -> TimeInterval {
        switch attempt {
        case ..<1: return 0
        case 1: return 0.5
        case 2: return 2
        default: return 5
        }
    }
}

// MARK: - Reasons

/// Why a readiness session ended. Recorded in the App Group so the keyboard —
/// a separate process, which never sees the app's in-memory error message —
/// can eventually say something truthful instead of a generic reconnect
/// prompt.
public enum InstantDictationReadinessEndReason: String, Codable, Equatable, Sendable {
    /// iOS took the audio session and it could not be restarted within the
    /// attempt budget.
    case audioUnavailable
    /// The session reached ``InstantDictationReadinessPolicy/sessionWindowSeconds``.
    case sessionWindowElapsed
    /// The shared App Group record could not be read or written.
    case storeUnavailable

    /// Short, user-facing explanation. Content-free: it names the class of
    /// failure, never a device, route or error string.
    public var readinessMessage: String {
        switch self {
        case .audioUnavailable:
            return "Instant Dictation stopped because the microphone stayed unavailable after an interruption."
        case .sessionWindowElapsed:
            return "Instant Dictation ended after four hours. Open Just Speak to start it again."
        case .storeUnavailable:
            return "Instant Dictation disconnected because its session state was unavailable."
        }
    }
}

// MARK: - Health

/// What one liveness tick saw.
public enum InstantDictationReadinessHealth: Equatable, Sendable {
    /// The readiness engine is running and holding the microphone.
    case running
    /// A dictation owns the microphone. Readiness is healthy and cannot expire.
    case recording
    /// The engine is not running.
    case stopped
}

/// What the tick should do about it.
public enum InstantDictationReadinessAction: Equatable, Sendable {
    case idle
    /// Wait `afterSeconds`, then try to restart the readiness engine. The
    /// caller reports the outcome back with ``InstantDictationReadinessMonitor/noteResume(succeeded:atSeconds:)``.
    case resume(afterSeconds: TimeInterval, attempt: Int)
    /// Stop, for this reason. The preference stays on: the failure is with
    /// this session, not with the user's choice.
    case end(InstantDictationReadinessEndReason)
}

// MARK: - Monitor

/// The bounds one readiness session is held to.
public struct InstantDictationReadinessMonitor: Equatable, Sendable {
    private let window: TimeInterval
    private let maximumAttempts: Int
    private let budgetResetSeconds: TimeInterval

    private var attempts = 0
    private var healthySinceSeconds: TimeInterval?
    private var finished = false

    public init(
        window: TimeInterval = InstantDictationReadinessPolicy.sessionWindowSeconds,
        maximumAttempts: Int = InstantDictationReadinessPolicy.maximumResumeAttempts,
        budgetResetSeconds: TimeInterval = InstantDictationReadinessPolicy.resumeBudgetResetSeconds
    ) {
        self.window = window
        self.maximumAttempts = maximumAttempts
        self.budgetResetSeconds = budgetResetSeconds
    }

    /// Attempts spent against the current budget. Exposed so the bound is
    /// assertable rather than only observable through its effects.
    public var spentResumeAttempts: Int { attempts }

    /// - Parameter seconds: elapsed time since the readiness session started.
    public mutating func observe(
        _ health: InstantDictationReadinessHealth,
        atSeconds seconds: TimeInterval
    ) -> InstantDictationReadinessAction {
        guard !finished else { return .idle }

        switch health {
        case .running, .recording:
            if healthySinceSeconds == nil { healthySinceSeconds = seconds }
            if let healthySince = healthySinceSeconds,
               attempts > 0,
               seconds - healthySince >= budgetResetSeconds {
                attempts = 0
            }
            // A dictation in progress is never interrupted by the window. The
            // expiry happens on the first tick after it finishes.
            if health == .running, seconds >= window {
                finished = true
                return .end(.sessionWindowElapsed)
            }
            return .idle

        case .stopped:
            healthySinceSeconds = nil
            guard attempts < maximumAttempts else {
                finished = true
                return .end(.audioUnavailable)
            }
            attempts += 1
            return .resume(
                afterSeconds: InstantDictationReadinessPolicy.resumeBackoffSeconds(attempt: attempts),
                attempt: attempts
            )
        }
    }

    /// Reports what a requested resume did. A success starts the health clock;
    /// it does *not* refund the attempt, which is what stops a session that
    /// dies every few seconds from resuming indefinitely.
    public mutating func noteResume(succeeded: Bool, atSeconds seconds: TimeInterval) {
        healthySinceSeconds = succeeded ? seconds : nil
    }

    /// Ends the monitor. Called when the session ends by any route, so a
    /// retired session's tick can never act.
    public mutating func retire() {
        finished = true
    }

    public var isRetired: Bool { finished }
}
