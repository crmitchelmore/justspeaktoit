import Foundation

// MARK: - Closed-set labels

/// Where a recording start entered *app code* (issue #972).
///
/// This is a bounded label for the invoking surface, not an inferred hardware
/// source: the same intent can be invoked from the Action Button, Siri,
/// Shortcuts or Control Center, and nothing on the start path can tell them
/// apart. Callers that have no earlier observation than the service or the
/// foreground coordinator say so explicitly with ``service`` / ``coordinator``
/// rather than borrowing a surface they cannot prove.
public enum StartupEntryOrigin: String, Sendable, CaseIterable {
    /// `StartTranscriptionIntent.perform()` entry.
    case startIntent
    /// `StartTranscriptionRecordingIntent.perform()` entry (the toggle).
    case toggleIntent
    /// `ToggleTranscriptionControlIntent.perform()` entry (Control Center).
    case controlToggleIntent
    /// The containing app began handling a keyboard handoff request, before
    /// credential loading and readiness teardown.
    case keyboardHandoff
    /// A foreground control in the app.
    case foreground
    /// A hands-free utterance started capture.
    case handsFree
    /// Headless service entry — no earlier app-code observation was supplied.
    case service
    /// Foreground coordinator entry — no earlier app-code observation was supplied.
    case coordinator
}

/// Which backend actually ran the start.
///
/// The Apple path resolves to ``appleAnalyzer`` or ``appleLegacy`` only when
/// that branch is actually taken, so a start that fails earlier reports no
/// backend rather than the one it intended to use.
public enum StartupBackend: String, Sendable, CaseIterable {
    case appleAnalyzer
    case appleLegacy
    case openAIRealtime
    case sharedClient
    case batch
    /// The DEBUG-only simulator transcript stub. It has no microphone, no
    /// audio session and no engine, so its timeline is explicitly synthetic
    /// and never carries an engine-start measurement.
    case simulatorStub
}

/// A boundary on the iOS start path, recorded only when it is actually
/// crossed. A stage that is never reached stays absent — never zero, and never
/// a fabricated success.
public enum StartupStage: String, Sendable, CaseIterable {
    /// The credentials wait (`ensureKeysLoaded`) completed.
    case credentialsReady
    /// The audio session finished configuring for recording.
    case audioSessionConfigured
    /// `audioEngine.start()` returned successfully. This is *not* proof of a
    /// first buffer, of usable speech, or of transport readiness.
    case engineStarted
    /// The backend's `start()` returned. This is *not* first audio and *not*
    /// provider readiness.
    case sessionStarted
    /// The first non-empty, non-final live partial arrived. Absent for batch,
    /// which has no live partial at all. This interval includes however long
    /// the user waited before speaking.
    case firstPartial

    /// Field name used in the emitted line.
    public var field: String {
        switch self {
        case .credentialsReady: return "credentials-ms"
        case .audioSessionConfigured: return "audio-session-ms"
        case .engineStarted: return "engine-start-ms"
        case .sessionStarted: return "session-start-ms"
        case .firstPartial: return "first-partial-ms"
        }
    }
}

/// How a start attempt ended. One summary is emitted per run, whichever it is.
public enum StartupOutcome: String, Sendable, CaseIterable {
    case started
    case failed
    case cancelled
}

/// The one thing a backend reports back through the existing session boundary.
public enum StartupObservation: Sendable, Equatable {
    case backend(StartupBackend)
    case stage(StartupStage)
}

/// The earliest app-code entry a caller could observe, and which surface
/// observed it. Passed down so an intent's `perform()` entry survives every
/// awaited helper between it and the start path.
public struct StartupEntry: Sendable, Equatable {
    public let origin: StartupEntryOrigin
    public let observedAt: Date

    public init(origin: StartupEntryOrigin, observedAt: Date = Date()) {
        self.origin = origin
        self.observedAt = observedAt
    }
}

// MARK: - Timeline

/// Wall-clock checkpoints for one iOS start attempt.
///
/// Offsets are whole milliseconds from the observed app-code entry, computed
/// with the same optional-interval helper the shared timeline uses
/// (``SessionLatencyMetrics/milliseconds(from:to:)``). These are `Date`
/// readings, so **no monotonic precision is claimed**: an interval that
/// measures negative under a clock adjustment is reported as absent, exactly
/// like a stage that was never reached. Absent therefore means "not reached or
/// not measurable", never zero.
public struct StartupTimeline: Sendable, Equatable {
    public let run: UUID
    public let origin: StartupEntryOrigin
    public let entryAt: Date
    /// `true` when `entryAt` came from a surface above the start path (an
    /// intent's `perform()` entry, a keyboard request); `false` when the start
    /// path timed its own entry.
    public let entryIsUpstream: Bool
    public private(set) var backend: StartupBackend?

    private var stages: [StartupStage: Date] = [:]

    public init(run: UUID, origin: StartupEntryOrigin, entryAt: Date, entryIsUpstream: Bool) {
        self.run = run
        self.origin = origin
        self.entryAt = entryAt
        self.entryIsUpstream = entryIsUpstream
    }

    /// Records `stage` the first time it is crossed.
    /// - Returns: `true` only for the first crossing, so a repeated callback
    ///   (a restarted recognition task, a second partial) cannot move a
    ///   boundary that was already measured.
    @discardableResult
    public mutating func mark(_ stage: StartupStage, at date: Date) -> Bool {
        guard stages[stage] == nil else { return false }
        stages[stage] = date
        return true
    }

    /// The backend refines as the start proceeds (Apple analyzer → legacy
    /// fallback), so the last observation wins.
    public mutating func resolve(backend: StartupBackend) {
        self.backend = backend
    }

    public func timestamp(of stage: StartupStage) -> Date? { stages[stage] }

    public func has(_ stage: StartupStage) -> Bool { stages[stage] != nil }

    /// Whole milliseconds from the observed entry to `stage`; `nil` when the
    /// stage was not reached or the interval is not measurable.
    public func offsetMilliseconds(of stage: StartupStage) -> Int? {
        SessionLatencyMetrics.milliseconds(from: entryAt, to: stages[stage])
    }

    /// Short, ephemeral correlation token. A prefix of the per-run identifier,
    /// which is created for this start and discarded with it — it identifies a
    /// run within one log, never a user or a device.
    public var runToken: String {
        String(run.uuidString.prefix(8)).lowercased()
    }

    /// The one summary line for this run. Every field is a closed-set label or
    /// a whole number of milliseconds; unreached stages are omitted.
    public func summaryLine(outcome: StartupOutcome) -> String {
        var fields = [
            "run=\(runToken)",
            "origin=\(origin.rawValue)",
            "entry=\(entryIsUpstream ? "upstream" : "local")",
            "backend=\(backend?.rawValue ?? "unresolved")",
            "outcome=\(outcome.rawValue)"
        ]
        for stage in StartupStage.allCases {
            guard let offset = offsetMilliseconds(of: stage) else { continue }
            fields.append("\(stage.field)=\(offset)")
        }
        return "startup " + fields.joined(separator: " ")
    }

    /// The at-most-one later observation, for a partial that arrives after the
    /// startup summary was already emitted.
    public func firstPartialLine() -> String? {
        guard let offset = offsetMilliseconds(of: .firstPartial) else { return nil }
        return "startup-partial run=\(runToken) origin=\(origin.rawValue) "
            + "backend=\(backend?.rawValue ?? "unresolved") \(StartupStage.firstPartial.field)=\(offset)"
    }
}

// MARK: - Recorder

/// Run-scoped collector for the iOS startup boundaries (issue #972).
///
/// **This measures startup; it does not make it faster.** It exists so a start
/// on a real device can be compared against another start on the same device,
/// with each boundary attributed to the step that actually crossed it.
///
/// Everything is stamped with the run that observed it, so a callback from a
/// retired or replaced run is dropped rather than attributed to its successor,
/// and a duplicate start cannot fabricate an engine-start event for a run that
/// never started an engine.
///
/// The emitted lines carry only the closed-set labels and whole-millisecond
/// numbers described on ``StartupTimeline``: no transcript, prompt, audio,
/// credential, raw error, device or route name, and no persistent identifier.
/// They go to the local unified log and nowhere else — this type performs no
/// network calls and no vendor reporting of any kind.
public struct StartupDiagnostics: Sendable {
    public typealias Sink = @Sendable (String) -> Void

    private var timeline: StartupTimeline?
    private var summaryEmitted = false
    private var partialEmitted = false
    private let now: @Sendable () -> Date
    private let emit: Sink

    /// - Parameters:
    ///   - now: the clock, injectable so each boundary can be proven in tests.
    ///   - emit: the line sink, injectable for the same reason. Defaults to the
    ///     local unified log.
    public init(
        now: @escaping @Sendable () -> Date = Date.init,
        emit: @escaping Sink = StartupDiagnostics.log
    ) {
        self.now = now
        self.emit = emit
    }

    /// Default sink: the local `startup` log category. Fields are public
    /// because they are an explicit content-free allowlist.
    public static let log: Sink = { line in
        SpeakLogger.startup.info("\(line, privacy: .public)")
    }

    /// The run currently being measured, if any.
    public var currentRun: UUID? { timeline?.run }

    /// The timeline as recorded so far. Exposed so a caller (and a test) can
    /// assert which boundaries were actually crossed.
    public var current: StartupTimeline? { timeline }

    /// Begins measuring `run`, retiring any predecessor's pending callbacks.
    ///
    /// - Parameters:
    ///   - entry: the earliest app-code entry the caller could observe. When
    ///     `nil` the start path times its own entry and says so.
    ///   - localOrigin: the label to use when there is no upstream entry.
    public mutating func begin(run: UUID, entry: StartupEntry?, localOrigin: StartupEntryOrigin) {
        timeline = StartupTimeline(
            run: run,
            origin: entry?.origin ?? localOrigin,
            entryAt: entry?.observedAt ?? now(),
            entryIsUpstream: entry != nil
        )
        summaryEmitted = false
        partialEmitted = false
    }

    /// Records one observation for `run`. Observations from any other run —
    /// a retired predecessor, a late backend callback — are dropped.
    public mutating func note(_ observation: StartupObservation, run: UUID) {
        guard var timeline, timeline.run == run else { return }
        switch observation {
        case .backend(let backend):
            // A backend refinement after the summary would describe a run that
            // was already reported; only the live run's backend is recorded.
            guard !summaryEmitted else { return }
            timeline.resolve(backend: backend)
            self.timeline = timeline
        case .stage(let stage):
            if stage == .firstPartial {
                noteFirstPartial(run: run)
                return
            }
            // After the summary the run's startup is over; only the deferred
            // first partial may still arrive.
            guard !summaryEmitted else { return }
            timeline.mark(stage, at: now())
            self.timeline = timeline
        }
    }

    /// Records the first non-empty, non-final live partial for `run`. Repeat
    /// calls are ignored, so the boundary is measured once and reported once.
    public mutating func noteFirstPartial(run: UUID) {
        guard var timeline, timeline.run == run, !partialEmitted else { return }
        guard timeline.mark(.firstPartial, at: now()) else { return }
        self.timeline = timeline
        guard summaryEmitted else { return }
        // The summary already went out, so this is the one deferred line.
        partialEmitted = true
        if let line = timeline.firstPartialLine() { emit(line) }
    }

    /// Emits the one startup summary for `run` and closes measurement.
    ///
    /// A successful start stays open just long enough for the first partial; a
    /// failed or cancelled start is retired immediately, so nothing that
    /// arrives afterwards can be attributed to it.
    public mutating func finish(_ outcome: StartupOutcome, run: UUID) {
        guard let timeline, timeline.run == run, !summaryEmitted else { return }
        summaryEmitted = true
        emit(timeline.summaryLine(outcome: outcome))
        if outcome != .started || timeline.has(.firstPartial) {
            drop()
        }
    }

    /// Ends the current run. Used on stop, cancel and teardown so a late
    /// callback cannot report against a run that is over.
    ///
    /// A run whose outcome was never reported is reported as ``cancelled``
    /// first. Teardown routinely runs *while the start is still suspended* — a
    /// user cancelling during startup — and the cancelled start's own catch
    /// block reaches the recorder only afterwards. Dropping the run outright
    /// would lose the attempt's diagnostics entirely, so the boundaries it did
    /// reach are emitted here. Because that is the run's one terminal outcome,
    /// the later `finish(.cancelled, run:)` finds nothing and stays silent, and
    /// no callback after it can be recorded.
    public mutating func retire() {
        if let timeline, !summaryEmitted {
            emit(timeline.summaryLine(outcome: .cancelled))
        }
        drop()
    }

    /// Drops the run without reporting it. Only valid once its summary has
    /// been emitted.
    private mutating func drop() {
        timeline = nil
        summaryEmitted = false
        partialEmitted = false
    }
}
