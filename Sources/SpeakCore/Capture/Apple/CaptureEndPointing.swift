// Silence end-pointing: deciding when a capture that nobody is going to press
// "stop" on should finish itself (issue #1012), and the input level maths that
// feeds that decision.
//
// Everything that *decides* anything lives here, pure and free of AV, Speech
// and UIKit, so the two cases that matter — cutting the user off mid-sentence,
// and never stopping at all — are proved by the host test suite rather than
// only being reachable by speaking into a device.
//
// The silence hold itself is `HandsFreeVoiceActivityTracker`, the same debounce
// hands-free dictation has used since it shipped. This file adds only what
// end-pointing needs on top of it: a speech-first gate, a warning edge, and a
// maximum duration.
import Foundation

// MARK: - Policy

/// The budgets an end-pointed capture runs to, in one place so the intent
/// parameters, the settings screen and the monitor cannot disagree.
public enum CaptureEndPointingPolicy {
    /// How long silence must hold before the capture finishes.
    ///
    /// The default is deliberately longer than hands-free's 2 s
    /// (``HandsFreeDictationPolicy/defaultSilenceHoldSeconds``). Hands-free
    /// re-arms after every utterance, so an early cut there costs the speaker a
    /// pause and nothing else. Here the capture is over: an early cut loses the
    /// rest of the sentence, and there is no way to resume it. Being cut off
    /// mid-thought is worse than a capture that runs three seconds long, so the
    /// window errs long.
    ///
    /// The range is the one issue #1012 asked for. The floor of 2 s is not
    /// arbitrary: ordinary speech carries pauses of well over a second at
    /// clause boundaries, and anything shorter would end-point inside a
    /// sentence rather than after it.
    public static let silenceWindowRange: ClosedRange<TimeInterval> = 2...8

    /// Default silence window. Chosen from the long end of what a natural
    /// speaking pause costs rather than the short end of what feels snappy.
    public static let defaultSilenceWindowSeconds: TimeInterval = 3.0

    /// How long before the stop the monitor raises ``CaptureEndPointingDecision/warning``,
    /// so a surface that can cue the user has something to cue them with.
    public static let warningLeadSeconds: TimeInterval = 1.0

    /// Bounds on the maximum duration of an end-pointed capture. The upper
    /// bound is an hour because that is the longest thing anyone plausibly
    /// dictates in one go; the lower bound keeps a caller from arming a
    /// capture that expires before the microphone is warm.
    public static let maximumDurationRange: ClosedRange<TimeInterval> = 5...3600

    /// Hard cap for a capture end-pointed from the settings toggle. Every
    /// end-pointed capture has one: a detector that never reports silence — a
    /// noisy room, a dead microphone reading as constant noise, a bug in this
    /// file — must not be able to leave a hot microphone running in a pocket.
    public static let defaultMaximumDurationSeconds: TimeInterval = 900

    /// Bounds and default for a one-shot Dictate *App Intent* (issue #1011).
    ///
    /// Shorter than the `dictate` URL verb's 120 s default in #1070, and that
    /// difference is deliberate rather than drift. The URL verb runs inside the
    /// foreground app, which has no budget on how long it may take. An App
    /// Intent's `perform()` does: below iOS 27 there is no `LongRunningIntent`
    /// to host a recording phase in, and an intent that overruns is ended by
    /// the system with nothing returned to the Shortcut. Twenty-five seconds is
    /// what issue #1011 records as fitting inside that budget. The ceiling is
    /// open to a minute for someone who knows their own shortcut runs in the
    /// foreground, and the intent says plainly what the risk is.
    public static let intentMaximumDurationRange: ClosedRange<TimeInterval> = 5...60
    public static let defaultIntentMaximumDurationSeconds: TimeInterval = 25

    /// Clamps a Dictate intent's requested deadline into
    /// ``intentMaximumDurationRange``.
    public static func intentMaximumDuration(configured value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultIntentMaximumDurationSeconds }
        return min(
            max(value, intentMaximumDurationRange.lowerBound),
            intentMaximumDurationRange.upperBound
        )
    }

    /// Input level, in dBFS, at or below which a sample counts as silence.
    ///
    /// Set low on purpose. Below the threshold the silence window starts
    /// running; above it, it resets. A threshold that is too low costs a
    /// capture that runs on until its maximum duration, which the user can
    /// still stop by hand. A threshold that is too high cuts them off while
    /// they are still speaking quietly, which they cannot undo. Room tone sits
    /// well under this; even a quiet voice sits well over it.
    public static let silenceThresholdDBFS: Float = -50

    /// How often the level is sampled. Fast enough that the window is accurate
    /// to a tenth of a second, slow enough to be free next to the audio work
    /// already happening on every buffer.
    public static let sampleIntervalSeconds: TimeInterval = 0.1

    /// Clamps a configured silence window into ``silenceWindowRange``.
    public static func silenceWindow(configured value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultSilenceWindowSeconds }
        return min(max(value, silenceWindowRange.lowerBound), silenceWindowRange.upperBound)
    }

    /// Clamps a configured maximum duration into ``maximumDurationRange``.
    public static func maximumDuration(configured value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultMaximumDurationSeconds }
        return min(max(value, maximumDurationRange.lowerBound), maximumDurationRange.upperBound)
    }

    /// Whether one level sample counts as speech.
    public static func speechDetected(
        levelDBFS: Float,
        threshold: Float = silenceThresholdDBFS
    ) -> Bool {
        levelDBFS > threshold
    }
}

// MARK: - Decisions

/// Why an end-pointed capture finished. Recorded so a capture that stopped
/// itself is distinguishable in the log from one the user stopped.
public enum CaptureEndPointingStopReason: String, Equatable, Sendable {
    /// Silence held for the whole window after the speaker had said something.
    case silence
    /// The capture hit its maximum duration. Always possible, whatever the
    /// detector did or failed to do.
    case maximumDuration
}

/// What the monitor makes of the capture so far.
public enum CaptureEndPointingDecision: Equatable, Sendable {
    /// Keep recording.
    case waiting
    /// The stop is ``CaptureEndPointingPolicy/warningLeadSeconds`` away.
    /// Raised at most once per run of silence, and re-armed when the speaker
    /// starts again.
    case warning
    /// Finish the capture now.
    case stop(CaptureEndPointingStopReason)
}

// MARK: - Request

/// A caller's request that a capture end-point itself.
///
/// Its presence is the whole decision: a capture started without one behaves
/// exactly as captures did before end-pointing existed, and stops only when
/// somebody stops it. Both budgets are clamped on the way in, so no surface can
/// arm a capture with a two-hour cap or a half-second window.
public struct CaptureEndPointingRequest: Equatable, Sendable {
    public let silenceWindow: TimeInterval
    public let maximumDuration: TimeInterval

    public init(
        silenceWindow: TimeInterval = CaptureEndPointingPolicy.defaultSilenceWindowSeconds,
        maximumDuration: TimeInterval = CaptureEndPointingPolicy.defaultMaximumDurationSeconds
    ) {
        self.silenceWindow = CaptureEndPointingPolicy.silenceWindow(configured: silenceWindow)
        self.maximumDuration = CaptureEndPointingPolicy.maximumDuration(configured: maximumDuration)
    }

    /// One line for the log, so a capture that stopped itself is traceable to
    /// the budgets it was armed with.
    public var logDescription: String {
        String(format: "silenceWindow=%.1fs maxDuration=%.0fs", silenceWindow, maximumDuration)
    }
}

// MARK: - Monitor

/// Turns a stream of voice-activity samples into the one decision an
/// end-pointed capture needs: stop, or keep going.
///
/// Three rules do the work, and the first two are what keep it from truncating
/// somebody mid-sentence:
///
/// 1. **Nothing stops on silence until speech has been heard.** A capture that
///    starts while the user is still drawing breath, unlocking the phone or
///    walking somewhere quieter can wait indefinitely. Only the maximum
///    duration can end a capture that never heard a voice — which is also the
///    behaviour when the level feed is broken or missing entirely, so a
///    plumbing failure produces a capture that runs long, never one that is
///    cut short.
/// 2. **Silence has to hold for the whole window**, via the same
///    ``HandsFreeVoiceActivityTracker`` hands-free uses. A single sample above
///    the threshold anywhere in the window resets it, so a mid-sentence breath
///    costs nothing.
/// 3. **The maximum duration always applies**, whatever the detector says. It
///    is the reason a broken detector cannot leave a microphone open.
///
/// The monitor latches once it has said stop, so a late sample can never ask
/// for a second stop.
public struct CaptureEndPointingMonitor: Equatable, Sendable {
    private var tracker = HandsFreeVoiceActivityTracker()
    private var heardSpeech = false
    private var warned = false
    private var stopped = false

    /// Clamped into ``CaptureEndPointingPolicy/silenceWindowRange``.
    public let silenceWindow: TimeInterval
    /// Clamped into ``CaptureEndPointingPolicy/maximumDurationRange``.
    public let maximumDuration: TimeInterval

    public init(
        silenceWindow: TimeInterval = CaptureEndPointingPolicy.defaultSilenceWindowSeconds,
        maximumDuration: TimeInterval = CaptureEndPointingPolicy.defaultMaximumDurationSeconds
    ) {
        self.silenceWindow = CaptureEndPointingPolicy.silenceWindow(configured: silenceWindow)
        self.maximumDuration = CaptureEndPointingPolicy.maximumDuration(configured: maximumDuration)
    }

    public init(_ request: CaptureEndPointingRequest) {
        self.init(
            silenceWindow: request.silenceWindow,
            maximumDuration: request.maximumDuration
        )
    }

    /// Whether the speaker has said anything yet. Until this is true nothing
    /// but the maximum duration can end the capture.
    public var hasHeardSpeech: Bool { heardSpeech }

    /// Whether the monitor has already asked for a stop.
    public var hasStopped: Bool { stopped }

    /// Feeds one sample.
    ///
    /// - Parameters:
    ///   - speechDetected: whether this sample carries speech. On iOS the level
    ///     gate in ``CaptureEndPointingPolicy/speechDetected(levelDBFS:threshold:)``
    ///     produces it; a `SpeechDetector` feed produces the same boolean, so
    ///     swapping one for the other changes nothing here.
    ///   - seconds: seconds since the capture started. A timeline that goes
    ///     backwards only restarts the silence window — it can never shorten it.
    public mutating func observe(
        speechDetected: Bool,
        atSeconds seconds: Double
    ) -> CaptureEndPointingDecision {
        guard !stopped else { return .waiting }

        if seconds >= maximumDuration {
            stopped = true
            return .stop(.maximumDuration)
        }

        let event = tracker.observe(
            speechDetected: speechDetected,
            atSeconds: seconds,
            silenceHoldSeconds: silenceWindow
        )
        if event == .speechDetected {
            heardSpeech = true
            warned = false
        }
        guard heardSpeech else { return .waiting }

        if event == .silenceElapsed {
            stopped = true
            return .stop(.silence)
        }

        guard !warned,
              let held = tracker.silenceHeld(atSeconds: seconds),
              held >= silenceWindow - CaptureEndPointingPolicy.warningLeadSeconds
        else { return .waiting }
        warned = true
        return .warning
    }

    /// Drops everything observed so far, for a monitor being reused on a new
    /// capture.
    public mutating func reset() {
        tracker.reset()
        heardSpeech = false
        warned = false
        stopped = false
    }
}

// MARK: - Level maths

/// Converts raw input levels into the decibel scale the silence threshold is
/// expressed in. Separated from any audio framework so the threshold arithmetic
/// is unit-tested on the host.
public enum AudioLevelMeter {
    /// Level reported for digital silence. Finite so callers never carry an
    /// infinity into arithmetic or a log line.
    public static let silenceFloorDBFS: Float = -120

    /// Root-mean-square of normalised (-1...1) samples, in dBFS.
    ///
    /// RMS rather than peak: a peak meter reads a single click in an otherwise
    /// silent room as speech and holds the capture open, and it reads the gaps
    /// between syllables as silence.
    public static func decibels(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return silenceFloorDBFS }
        return max(silenceFloorDBFS, 20 * log10(rms))
    }

    /// RMS of a block of normalised samples, in dBFS.
    public static func decibels<S: Sequence>(samples: S) -> Float where S.Element == Float {
        var sumOfSquares: Double = 0
        var count = 0
        for sample in samples {
            sumOfSquares += Double(sample) * Double(sample)
            count += 1
        }
        guard count > 0 else { return silenceFloorDBFS }
        return decibels(rms: Float((sumOfSquares / Double(count)).squareRoot()))
    }
}
