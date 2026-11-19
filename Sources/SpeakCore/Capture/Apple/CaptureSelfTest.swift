// The headless microphone self-test behind the Capture Health screen
// (issue #997).
//
// What it does, and why it is shaped this way:
//
// The self-test opens the microphone, counts real input buffers, and closes
// it. It does **not** go through `TranscriptionRecordingService`, and that is
// the whole design. Every side effect the issue warns about — a History row,
// an overwritten clipboard, an unrequested Live Activity, a destination
// delivery — lives on the far side of that service, so a self-test that never
// calls it cannot produce one. The absence is structural rather than a set of
// suppression flags somebody has to remember to pass.
//
// It also does not need the user to speak. A live input tap delivers buffers
// in a silent room exactly as it does in a loud one, because a buffer of
// silence is still a buffer — the same fact ``CaptureWatchdogPolicy``'s
// no-input bound rests on. That matters because the failure this screen
// exists for is a silent one, and asking somebody to talk in order to
// diagnose "nothing happens when I talk" is not a diagnosis.
//
// The price of that is an honest list of what it cannot settle, carried in
// the result itself so no caller can present a pass as more than it is. See
// ``CaptureSelfTestLimit``.
import Foundation

// MARK: - Stages

/// The boundaries the self-test crosses, in order. Each is a real step, and
/// each is recorded only when it is actually reached.
public enum CaptureSelfTestStage: String, Equatable, Sendable, CaseIterable {
    /// Recording permission was granted.
    case permission
    /// The audio session was configured and activated for recording.
    case audioSession
    /// `AVAudioEngine.start()` returned.
    case engine
    /// A real input buffer with frames in it arrived from the tap.
    case firstInput

    public var label: String {
        switch self {
        case .permission: return "microphone permission"
        case .audioSession: return "audio session setup"
        case .engine: return "starting the audio engine"
        case .firstInput: return "waiting for audio from the microphone"
        }
    }

    /// What a failure here means for the user, in the words the health row
    /// shows.
    public var failureMeaning: String {
        switch self {
        case .permission:
            return "This app is not allowed to use the microphone."
        case .audioSession:
            return "The system would not give this app the microphone, usually because another app holds it."
        case .engine:
            return "The audio engine would not start with the current input device."
        case .firstInput:
            return "The microphone was opened but sent no audio at all. This is the silent failure this screen "
                + "exists to catch."
        }
    }
}

/// Things a self-test with nobody speaking cannot settle. Carried in the
/// result so a pass is never read as more than it is.
public enum CaptureSelfTestLimit: String, Equatable, Sendable, CaseIterable {
    /// Whether the words come back right. That needs a person speaking.
    case transcriptionAccuracy
    /// Whether the chosen cloud provider accepts a session and returns text.
    /// The self-test never opens a provider connection.
    case providerRoundTrip
    /// Whether a stop is detected at the right moment.
    case endpointing
    /// Whether the provider key is readable while the device is locked. It
    /// cannot be, by definition, while somebody is looking at this screen
    /// (issue #930).
    case lockedDeviceCredentialAccess
    /// Whether a hardware trigger — Action Button, Control, widget — reaches
    /// the app. Only a real press proves that.
    case headlessTriggerDelivery

    public var explanation: String {
        switch self {
        case .transcriptionAccuracy:
            return "Whether the words come back correctly. That needs you to speak."
        case .providerRoundTrip:
            return "Whether your cloud provider accepts a session and returns text. The test never connects to one."
        case .endpointing:
            return "Whether a capture stops when you stop talking."
        case .lockedDeviceCredentialAccess:
            return "Whether your provider key can be read while the phone is locked, which cannot be tested "
                + "while you are looking at this screen."
        case .headlessTriggerDelivery:
            return "Whether the Action Button, a Control or a widget reaches the app. Only a real press shows that."
        }
    }
}

public enum CaptureSelfTestOutcome: Equatable, Sendable {
    case passed
    case failed(CaptureSelfTestStage)
    case cancelled
}

public struct CaptureSelfTestResult: Equatable, Sendable {
    public let outcome: CaptureSelfTestOutcome
    /// Input buffers the tap actually delivered.
    public let observedBuffers: Int
    /// Whole milliseconds from the start of the test to its end.
    public let elapsedMilliseconds: Int
    /// Milliseconds to each boundary that was crossed. Unreached stages are
    /// absent — never zero.
    public let stageMilliseconds: [CaptureSelfTestStage: Int]
    /// What this run could not settle. Always non-empty: there is no self-test
    /// that answers everything.
    public let limits: [CaptureSelfTestLimit]

    public init(
        outcome: CaptureSelfTestOutcome,
        observedBuffers: Int,
        elapsedMilliseconds: Int,
        stageMilliseconds: [CaptureSelfTestStage: Int],
        limits: [CaptureSelfTestLimit] = CaptureSelfTestLimit.allCases
    ) {
        self.outcome = outcome
        self.observedBuffers = observedBuffers
        self.elapsedMilliseconds = elapsedMilliseconds
        self.stageMilliseconds = stageMilliseconds
        self.limits = limits
    }
}

// MARK: - Policy

public enum CaptureSelfTestPolicy {
    /// How long the test holds the microphone open waiting for a buffer.
    ///
    /// Two seconds: long enough that a hardware buffer period (a few tens of
    /// milliseconds) is not in question, short enough that the microphone is
    /// never open for a length of time the user would notice or worry about.
    public static let inputWindowSeconds: TimeInterval = 2

    /// The whole test's ceiling, including setup. Past this the run is
    /// abandoned and the microphone closed regardless of which step hung, so
    /// a stall in `AVAudioSession` cannot leave a hot microphone behind.
    public static let overallDeadlineSeconds: TimeInterval = 8

    /// Buffers required before the microphone is called alive. One real
    /// buffer with frames in it is proof; more would only add latency.
    public static let requiredBuffers = 1
}

// MARK: - The run

/// The self-test's state machine, with the clock passed in.
///
/// The reason this is a pure value and not just code inside the iOS driver is
/// that the branches that matter are the failing ones — no permission, an
/// engine that starts and never delivers a buffer, a cancellation halfway —
/// and those are exactly the branches a simulator run will not produce on
/// demand. Here `swift test` walks every one of them.
public struct CaptureSelfTestRun: Equatable, Sendable {
    private var stages: [CaptureSelfTestStage: Int] = [:]
    private var buffers = 0
    private var terminal: CaptureSelfTestOutcome?
    private var endedAtMilliseconds: Int?
    private let requiredBuffers: Int
    private let deadlineSeconds: TimeInterval

    public init(
        requiredBuffers: Int = CaptureSelfTestPolicy.requiredBuffers,
        deadlineSeconds: TimeInterval = CaptureSelfTestPolicy.overallDeadlineSeconds
    ) {
        self.requiredBuffers = max(1, requiredBuffers)
        self.deadlineSeconds = deadlineSeconds
    }

    /// True once the audio session or engine has been touched and the run has
    /// not finished — i.e. exactly while the caller owes a teardown.
    ///
    /// The iOS driver tears down unconditionally in a `defer` regardless; this
    /// exists so a test can assert that no path through the machine leaves the
    /// obligation outstanding after `finish`.
    public var owesTeardown: Bool {
        self.terminal == nil && self.stages[.audioSession] != nil
    }

    public var isFinished: Bool { self.terminal != nil }

    public var observedBuffers: Int { self.buffers }

    /// Records a boundary the first time it is crossed. Later crossings are
    /// ignored, so a restarted engine cannot move a measured boundary.
    public mutating func note(_ stage: CaptureSelfTestStage, atMilliseconds elapsed: Int) {
        guard self.terminal == nil, self.stages[stage] == nil else { return }
        self.stages[stage] = max(0, elapsed)
    }

    /// Records one delivered input buffer with frames in it. Empty buffers are
    /// the caller's to filter: this counts proof of audio, not callbacks.
    ///
    /// - Returns: `true` when this buffer satisfied the requirement, so the
    ///   driver can stop immediately rather than holding the microphone for
    ///   the rest of the window.
    @discardableResult
    public mutating func noteInputBuffer(atMilliseconds elapsed: Int) -> Bool {
        guard self.terminal == nil else { return false }
        self.buffers += 1
        if self.buffers >= self.requiredBuffers {
            self.note(.firstInput, atMilliseconds: elapsed)
            return true
        }
        return false
    }

    /// Ends the run because a step failed.
    public mutating func fail(at stage: CaptureSelfTestStage, atMilliseconds elapsed: Int) {
        guard self.terminal == nil else { return }
        self.terminal = .failed(stage)
        self.endedAtMilliseconds = max(0, elapsed)
    }

    /// Ends the run because the user left or asked it to stop.
    public mutating func cancel(atMilliseconds elapsed: Int) {
        guard self.terminal == nil else { return }
        self.terminal = .cancelled
        self.endedAtMilliseconds = max(0, elapsed)
    }

    /// Ends the run at the end of its input window, or at the overall
    /// deadline. Passing requires a real buffer: an engine that started and
    /// delivered nothing is a failure at ``CaptureSelfTestStage/firstInput``,
    /// never a pass with a zero count.
    public mutating func finish(atMilliseconds elapsed: Int) -> CaptureSelfTestResult {
        if self.terminal == nil {
            self.endedAtMilliseconds = max(0, elapsed)
            if self.buffers >= self.requiredBuffers {
                self.terminal = .passed
            } else {
                self.terminal = .failed(self.stalledStage())
            }
        }
        return self.result()
    }

    /// The result as it stands. Callable after `finish`; before it, reports
    /// the run as cancelled, because an unfinished run has not passed.
    public func result() -> CaptureSelfTestResult {
        CaptureSelfTestResult(
            outcome: self.terminal ?? .cancelled,
            observedBuffers: self.buffers,
            elapsedMilliseconds: self.endedAtMilliseconds ?? self.stages.values.max() ?? 0,
            stageMilliseconds: self.stages,
            limits: CaptureSelfTestLimit.allCases
        )
    }

    /// True when `elapsed` has passed the overall ceiling, so the driver
    /// abandons the run and closes the microphone.
    public func hasPassedDeadline(atMilliseconds elapsed: Int) -> Bool {
        Double(elapsed) / 1000 >= self.deadlineSeconds
    }

    /// The earliest boundary that was never crossed — where the run stalled.
    private func stalledStage() -> CaptureSelfTestStage {
        for stage in CaptureSelfTestStage.allCases where self.stages[stage] == nil {
            return stage
        }
        return .firstInput
    }
}
