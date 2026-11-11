#if os(iOS)
import Foundation
import UIKit
import SpeakCore

/// Headless recording coordinator for Action Button / Shortcuts / Siri.
/// Manages the full lifecycle: start recording → live transcription → stop → clipboard → Live Activity.
@MainActor
public final class TranscriptionRecordingService: ObservableObject {
    public static let shared = TranscriptionRecordingService()

    /// The service's lifecycle state, mirrored from the run-identity
    /// coordinator after every transition. `isRunning` remains as the
    /// published `recording`-only view for existing observers.
    @Published public internal(set) var state: RecordingServiceState = .idle

    /// Whether a stop/toggle has an operation to act on: a live recording or
    /// a startup still in flight (which stop will cancel).
    public var isActive: Bool { lifecycle.isActive }

    @Published public internal(set) var isRunning = false
    @Published public internal(set) var partialText = ""
    @Published public internal(set) var wordCount = 0
    /// Nonfatal audio-loss notice, separate from errors that stop recording.
    @Published public internal(set) var recordingWarning: String?
    var recordingWarningRunID = UUID()
    /// Error that ended the most recent session mid-recording. Published so the
    /// app can surface it on next foreground instead of silently losing audio.
    @Published public internal(set) var lastSessionError: Error? {
        didSet {
            // A fresh identity per publication, even for a repeated failure (#1084).
            sessionErrorToken = health.publishSessionError(lastSessionError)
            // One funnel for every capture failure, so the health screen can
            // report how the last real run ended rather than only what is
            // true this second (issue #997). The journal keeps a closed-set
            // label, local diagnostic code and a date — never the error's text.
            guard let lastSessionError else { return }
            health.journal(failure: lastSessionError)
        }
    }
    /// Identifies the *publication* of `lastSessionError`, not its text, so a
    /// failure that reads identically to the last one is still a new event.
    @Published public internal(set) var sessionErrorToken: UUID?
    /// Non-nil when the session silently fell back to on-device transcription
    /// because the selected cloud model had no API key available.
    @Published public internal(set) var providerFallbackNotice: String?
    /// What the last completed capture actually did with the transcript
    /// (issue #1008). Built from observed results, never from intentions, so
    /// it is safe for any surface to render verbatim.
    @Published public internal(set) var lastCaptureReceipt: CaptureReceipt?

    /// Whether the background polish started by the most recent stop is still
    /// running, and what it produced (issue #1015).
    ///
    /// Published so a returning intent can opt in to waiting for the polished
    /// text instead of handing a Shortcut the raw transcript while the
    /// clipboard is about to hold a different one. `lastPolishedTranscript`
    /// stays `nil` when the polish failed or was never started, which is what
    /// keeps the wait honest: the caller falls back to the raw transcript
    /// rather than being told nothing came back.
    @Published public private(set) var isPostProcessing = false
    @Published public private(set) var lastPolishedTranscript: String?
    /// Which capture's polish `isPostProcessing` and `lastPolishedTranscript`
    /// describe.
    ///
    /// Both used to be service-wide with no owner, so recording B could start,
    /// stop and begin waiting while A was still polishing; A would then write
    /// its own result and clear the flag, and B's waiter would return A's
    /// text. Completion state belongs to a particular stop, so it is tagged
    /// with one.
    @Published public private(set) var polishingRunID: UUID?
    /// The owned completion and polish state the three properties above
    /// project; see `CapturePolishLedger`.
    var polishLedger = CapturePolishLedger() {
        didSet {
            guard polishLedger != oldValue else { return }
            if lastPolishedTranscript != polishLedger.polishedTranscript {
                lastPolishedTranscript = polishLedger.polishedTranscript
            }
            if isPostProcessing != polishLedger.isPostProcessing { isPostProcessing = polishLedger.isPostProcessing }
            if polishingRunID != polishLedger.polishingRunID { polishingRunID = polishLedger.polishingRunID }
        }
    }

    /// What one capture finished with, tagged with the session that produced it.
    ///
    /// A caller that starts a capture does not necessarily own its stop — the
    /// Live Activity, the Action Button and `justspeaktoit://stop` can all end
    /// it — and "the last completed transcript" in the App Group is a global
    /// that a *later* recording overwrites. Anything waiting on a result it did
    /// not stop needs to be able to tell one session's outcome from another's,
    /// and to tell an empty transcript apart from a failed one.
    public struct FinishedCapture: Sendable, Equatable {
        /// The session this outcome belongs to, matching `currentSessionID` at
        /// the time that session was started.
        public let sessionID: UUID
        /// The transcript, which is legitimately empty when nothing was said.
        public let text: String
        /// Set when the session ended in a provider or recording error, in
        /// which case `text` is whatever had accumulated and is not an answer.
        public let failureMessage: String?

        public var failed: Bool { self.failureMessage != nil }
    }

    /// Identifies the capture currently starting or running, from the moment
    /// `startRecording` commits to it until it finishes.
    @Published public internal(set) var currentSessionID: UUID?

    /// The most recent capture to finish, whoever stopped it. Published after
    /// the transcriber has drained and the transcript has been committed, so a
    /// waiter that sees its own session id here is reading a settled result.
    @Published public internal(set) var lastFinishedCapture: FinishedCapture?

    let audioSessionManager = AudioSessionManager()
    let dependencies: RecordingServiceDependencies
    let settings: AppSettings
    let focusOverride: @MainActor (CaptureRunParameters) async throws -> FocusCaptureOverride
    let activityManager: RecordingServiceActivity
    let sharedState: SharedTranscriptionState
    let historyManager: iOSHistoryManager
    let foregroundOwnership: ForegroundRecordingOwnership
    let ensureKeysLoaded: @MainActor () async -> Void
    let networkSnapshot: CaptureNetworkPathMonitor.SnapshotProvider
    let localRecognitionCapability: @MainActor (String) -> AppleLocalRecognitionCapability

    var transcriptionSession: (any IOSRecordingSession)?
    var stoppingSession: (any IOSRecordingSession)?
    /// Test seam: lets lifecycle tests inject a session without a microphone or provider.
    var makeSession: (() throws -> any IOSRecordingSession)?
    /// A controlled stop reason (an audio interruption) that is not a failure.
    /// Cleared at the start of every run; never populates `lastSessionError`.
    @Published var captureStopNotice: String?
    var startTime: Date?
    var currentModel: String = ""
    var sharesLiveTranscript = true
    var sharedTranscriptRequested = true
    var automaticStopDestination: HardwareTriggerDestination = .clipboard
    var onCaptureDisruption: (() async -> Void)?
    /// Which trigger started the session in flight, so onboarding can only
    /// mark a trigger proven when a transcript really arrived through it.
    /// `nil` means the caller did not identify itself, and nothing is claimed.
    var currentTrigger: CaptureTrigger?
    /// Per-run parameter overrides supplied by the surface that started the
    /// session (issue #1013). They travel with the run so every stop path —
    /// the Live Activity button, a Siri stop, a quick action, an interruption
    /// — finishes where the caller asked, not where the global setting says.
    /// `.none` is the pre-parameter behaviour in every respect.
    var currentRunParameters: CaptureRunParameters = .none
    var effectiveConfiguration: EffectiveCaptureConfiguration?
    var effectiveDestination: CaptureDestinationSelection?
    var lastCompletedDestination: CaptureDestinationSelection?

    public var captureDestinationStatus: String? {
        guard let effectiveConfiguration,
              let destination = HardwareTriggerDestination(rawValue: effectiveConfiguration.destinationID)
        else { return nil }
        return destination.displayName + (effectiveConfiguration.destinationOrigin == .focus ? " · Focus" : "")
    }
    /// Run identity and the transcript each run committed; see `CaptureRunLedger`.
    var runLedger = CaptureRunLedger()
    /// Identity of the capture in flight. `nil` once that capture has settled.
    var currentRunID: UUID? { runLedger.currentRunID }
    /// Request diagnostics, staged issue snapshots and the outcome journal.
    var health: CaptureHealthReporter

    func issueSnapshot(for token: UUID?) -> IOSIssueReportSnapshot { health.snapshot(for: token) }

    func publishRequestFailure(_ error: Error, failure: RequestDiagnosticContext.Failure) {
        health.stageFailure(error, failure: failure, run: currentRunID)
        lastSessionError = error
    }
    /// Closed typed cause retained while this startup owns cancellation cleanup.
    var startupWatchdogFailure: (runID: UUID, error: iOSTranscriptionError)?
    /// Run-identity state machine for cancellable startup (issue #701); the
    /// pure mechanics live in SpeakCore so they are testable on every
    /// platform. `state` mirrors it for observers.
    let lifecycle = RecordingLifecycleCoordinator()
    /// Truthful capture presentation (issue #983): startup stays visibly
    /// "preparing" until this run has both started its backend and observed a
    /// buffer from its own live input tap.
    var presentation = CapturePresentationGate()
    /// Local run-scoped startup timing (issue #972). Measurement only: it adds
    /// no network call, no vendor reporting and no behaviour change.
    var diagnostics = StartupDiagnostics()
    /// The bounds this run is held to (issue #993). Every rule lives in
    /// SpeakCore's `CaptureWatchdogMonitor`; see
    /// `TranscriptionRecordingService+Watchdogs.swift` for the wiring.
    var watchdog = CaptureWatchdogMonitor()
    var watchdogTask: Task<Void, Never>?
    var watchdogRunID: UUID?
    var watchdogStartedAt: Date?
    /// The armed silence end-pointing monitor's poll loop (issue #1012), or
    /// `nil` when this capture runs until somebody stops it. See
    /// `TranscriptionRecordingService+EndPointing.swift`.
    var endPointingTask: Task<Void, Never>?
    /// The session whose transcript is being delivered by the stop in
    /// progress. Held only across delivery so a non-retained batch capture's
    /// recording can be discarded *after* its transcript has landed, never at
    /// the moment the provider replied.
    var deliveringSession: (any IOSRecordingSession)?
    /// The cloud model this run would have used had the network been up,
    /// when offline routing substituted on-device recognition (issue #999).
    var offlineIntendedModel: String?
    /// Rate limit for App Group writes of live partials.
    var sharedStateWrites = SharedTranscriptWriteThrottle()

    let polishClipboard: PolishClipboard
    let hasPolishingKey: @MainActor () -> Bool
    let polish: @MainActor (String, String, String) async throws -> String
    typealias ActivityCompletion =
        @MainActor (Int, Int, String, TranscriptionCompletionOutcome, String, String?, String) -> Void
    typealias OwnedActivityCompletion =
        @MainActor (Int, Int, String, TranscriptionCompletionOutcome, String, String?, String, UUID) -> Void
    let completeActivity: ActivityCompletion
    let completeOwnedActivity: OwnedActivityCompletion?
    let sessionFactory: (() throws -> IOSTranscriptionSession)?

    private convenience init() {
        let settings = AppSettings.shared
        let clipboard = TranscriptClipboard(
            pasteboard: UIPasteboard.general,
            now: Date.init,
            policy: { settings.transcriptClipboardPolicy }
        )
        self.init(
            sharedState: .shared,
            historyManager: .shared,
            polishClipboard: PolishClipboard(pasteboard: SystemPolishPasteboard(clipboard: clipboard)),
            hasPolishingKey: { settings.hasPostProcessingKey },
            polish: { text, model, apiKey in
                try await iOSPostProcessingManager.shared.polish(text: text, model: model, apiKey: apiKey)
            },
            networkSnapshot: CaptureNetworkPathMonitor.liveSnapshotProvider(),
            localRecognitionCapability: AppleLegacyRecognitionCapabilityProbe.capability(for:),
            dependencies: .live(settings: settings)
        )
    }

    /// Keeps recording lifecycle tests isolated from the real clipboard, History and provider.
    init(
        sharedState: SharedTranscriptionState,
        historyManager: iOSHistoryManager,
        polishClipboard: PolishClipboard,
        hasPolishingKey: @escaping @MainActor () -> Bool,
        polish: @escaping @MainActor (String, String, String) async throws -> String,
        completeActivity: ActivityCompletion? = nil,
        sessionFactory: (() throws -> IOSTranscriptionSession)? = nil,
        foregroundOwnership: ForegroundRecordingOwnership? = nil,
        ensureKeysLoaded: (@MainActor () async -> Void)? = nil,
        networkSnapshot: @escaping CaptureNetworkPathMonitor.SnapshotProvider = { .unknown },
        localRecognitionCapability: @escaping @MainActor (String) -> AppleLocalRecognitionCapability =
            { _ in .available },
        dependencies: RecordingServiceDependencies? = nil,
        outcomeJournalDefaults: @escaping @MainActor () -> UserDefaults? = { CaptureOutcomeJournal.defaults }
    ) {
        // Injected constructors without dependencies retain a no-op Focus seam.
        self.focusOverride = dependencies?.focusOverride ?? { _ in .none }
        let dependencies = dependencies ?? .live()
        self.dependencies = dependencies
        self.settings = dependencies.settings
        self.activityManager = dependencies.activity
        self.sessionFactory = sessionFactory
        self.health = CaptureHealthReporter(journalDefaults: outcomeJournalDefaults)
        self.foregroundOwnership = foregroundOwnership ?? .shared
        self.ensureKeysLoaded = ensureKeysLoaded ?? { await dependencies.settings.ensureKeysLoaded() }
        self.networkSnapshot = networkSnapshot
        self.localRecognitionCapability = localRecognitionCapability
        self.sharedState = sharedState
        self.historyManager = historyManager
        self.polishClipboard = polishClipboard
        self.hasPolishingKey = hasPolishingKey
        self.polish = polish
        self.completeActivity = completeActivity ?? dependencies.activity.complete
        // An existing injected completion callback keeps complete ownership of its effects.
        self.completeOwnedActivity = completeActivity == nil ? dependencies.activity.completeOwned : nil
    }

    /// Picks the first non-blank candidate, else the fallback. Extracted as a
    /// pure function so the stop-time text-selection priority
    /// (result → interim → last-completed) is unit-testable.
    static func bestTranscript(candidates: [String], fallback: String) -> String {
        for candidate in candidates
        where !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return candidate
        }
        return fallback
    }

    var elapsedSeconds: Int {
        guard let start = startTime else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }

    var modelDisplayName: String {
        ModelCatalog.transcriptionDisplayName(
            for: currentModel,
            isBatch: transcriptionSession?.isBatch
                ?? effectiveConfiguration?.usesBatch
                ?? (settings.transcriptionMode == .batch)
        )
    }

    /// Cancels recording without saving. During startup this retires the
    /// pending run and cancels its allocated provider immediately. The owned
    /// startup task unwinds before another run can begin (issues #701, #786).
    public func cancelRecording() {
        // A completed recording's polish has its own lifetime. Cancelling a
        // subsequent capture must not cancel that work or invalidate its result.
        if lifecycle.state == .stopping {
            polishLedger.retireCompletion()
            // The current finalisation keeps ownership until its drain ends.
            // A replacement must not start while it can still publish output.
            return
        }
        currentTrigger = nil
        disarmEndPointing()
        // The cancelled run's loss notice describes a recording that is being
        // discarded; retire it with the run so a later capture cannot inherit it.
        recordingWarningRunID = UUID()
        recordingWarning = nil
        if lifecycle.state == .starting {
            lifecycle.retireStartRun()
            return
        }
        // A cancelled session still has to settle for anything waiting on it:
        // an empty outcome is what a cancel produced, and a waiter must not be
        // left reading the previous recording's result instead.
        self.publishFinishedCapture(text: "", failure: nil)
        transcriptionSession?.cancel()
        transcriptionSession = nil
        currentRunParameters = .none
        effectiveConfiguration = nil
        effectiveDestination = nil
        sharesLiveTranscript = true
        isRunning = false
        presentation.finish()
        diagnostics.retire()
        disarmWatchdogs()
        startTime = nil
        partialText = ""
        wordCount = 0
        sharedState.clearRecordingState()
        activityManager.endActivity()
        // A cancelled capture completes empty for its own run, so a waiter
        // returns nothing rather than an earlier capture's transcript.
        completeRun(with: "")
        lifecycle.finishStopping()
        state = lifecycle.state
    }
}

#endif
